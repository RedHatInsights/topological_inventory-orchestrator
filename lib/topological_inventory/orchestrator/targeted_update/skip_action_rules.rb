module TopologicalInventory
  module Orchestrator
    class TargetedUpdate
      module SkipActionRules
        # If event is an application's event then only supported applications should be processed
        # Unsupported applications switched to :action => :skip
        #
        def skip_unsupported_applications
          app_events = @targets.select { |target| target[:target] == :application }

          if app_events.present?
            app_type_ids = @api.send(:supported_application_type_ids)

            app_events.each do |target|
              app = target[:application]
              unless app_type_ids.include?(app['application_type_id'].to_s)
                log_msg_for_target(target, "skipped as unsupported app (#{app.attributes})", :debug)
                target[:action] = :skip
              end
            end
          end
        end

        # If Source or SourceType not loaded by API
        # skip this event
        def skip_targets_without_source(target)
          skip = (!source_loaded?(target) || !source_type_loaded?(target))

          target[:action] = :skip if skip
          skip
        end

        # If there are more supported applications associated with Source,
        # skip this 'destroy application' event
        def skip_destroy_action_of_non_last_app(target)
          if target[:action] == :destroy && target[:target] == :application
            orig_app = target[:application]
            target[:application] = nil
            load_applications

            if target[:application].present?
              log_msg_for_target(target, "Event skipped, another supported application found", :debug)
              target[:action] = :skip
            else
              target[:application] = orig_app
            end
          end
        end

        # Actions create and update are joined to "upsert" method,
        # so it doesn't need to be skipped and we save API calls.
        def skip_create_action_of_non_first_app(_target)
          nil
        end

        # Skip the same actions (i.e. creating a Source through UI generates multiple events)
        def skip_targets_with_same_source_and_action
          @targets.each do |target|
            @targets.each do |target2|
              next unless target[:source]['id'] == target2[:source]['id'] &&
                          target[:action] == target2[:action] &&
                          target[:target] != target2[:target]

              target[:action] = :skip
              break
            end
          end
        end
      end
    end
  end
end
