require 'scout'

class SwfTasks < Scout::Plugin
  needs 'aws-sdk'
  needs 'yaml'
  needs 'json'

  MAPPING = {
    /scrivitocom/ => "dashboard",
    /crm/ => "crm",
    /console/ => "console",
    /scriv.*cms/ => "backend",
    /cms/ => "cms",
  }

  def app_name_from_unit(execution)
    first_event = execution.history_events.first
    input_as_json = first_event.attributes[:input]
    if input_as_json
      input = JSON(input_as_json)
      unit = input["unit"]
      match = MAPPING.keys.detect {|pattern, app| unit =~ pattern}
      match ? MAPPING[match] : "unknown"
    end
  end

  def app_name_from_event(event)
    execution = event.workflow_execution
    app_name_from_unit(execution) || "unknown"
  end

  def metric_key(name, app_or_event)
    app =
        case app_or_event
        when String
          app_or_event
        else
          app_name_from_event(app_or_event)
        end
    "#{app}_#{name}_tasks"
  end

  def swf_config
    @swf_config ||= YAML.load_file("/home/scout/swf_tasks.yml")
  end

  def swf_domain
    domain = AWS::SimpleWorkflow.new({
      :access_key_id => swf_config["simple_workflow_access_key_id"],
      :secret_access_key => swf_config["simple_workflow_secret_access_key"],
      :simple_workflow_endpoint => swf_config["simple_workflow_endpoint"],
      :use_ssl => true,
    }).domains[swf_config["simple_workflow_domain"]]
  end

  def open_executions
    swf_domain.workflow_executions.with_status(:open)
  end

  def my_host
    @hostname ||= `hostname`.strip
  end

  def foreign_stack?(stack_id)
    my_stack_id = swf_config["stack_id"]
    my_stack_id && stack_id != my_stack_id
  end

  def parse_identity(identity)
    hostname, pid, stack_id = identity.split(":")
    raise "Unexpected identity #{identity} - cannot split by :" unless pid
    raise "Unexpected pid #{pid} from identity #{identity}" unless pid.to_i.to_s == pid
    [hostname, pid, stack_id]
  end

  def zombie?(event)
    identity = event.attributes[:identity] or
        raise "Missing identity in event: attributes = #{event.attributes}"
    hostname, pid, stack_id = parse_identity(identity)
    return false unless hostname == my_host
    # requires stack_id to be both configured via config and provided by event
    return false if stack_id && foreign_stack?(stack_id)
    return false if File.exists?("/proc/#{pid}")
    # the inspected event is still the last event of the execution
    return false unless event.id == event.workflow_execution.history_events.reverse_order.first.id
    log_zombie(event)
    true
  end

  def log_zombie(event)
    w = event.workflow_execution
    File.open(File.expand_path("~/swf_tasks.log"), "a") do |f|
      f.puts %|[#{Time.now}] Zombie (execution: Rails.application.workflow.ntswf.domain.workflow_executions.at["#{w.workflow_id}", "#{w.run_id}"] details: #{w.history_events.first.attributes.to_h})|
    end
  end

  def statistics
    @statistics ||= begin
      statistics = Hash.new(0)
      %w[waiting zombie].each do |type|
        MAPPING.values.each do |app|
          statistics[metric_key(type, app)] = 0
        end
      end
      statistics
    end
  end

  def build_report
    open_executions.each do |ex|
      last_event = ex.history_events.reverse_order.first
      case last_event.event_type
      when "ActivityTaskScheduled"
        statistics[metric_key("waiting", last_event)] += 1
      when "ActivityTaskStarted", "DecisionTaskStarted"
        if zombie?(last_event)
          statistics[metric_key("zombie", last_event)] += 1
        end
      end
    end
    report(statistics)
  end
end
