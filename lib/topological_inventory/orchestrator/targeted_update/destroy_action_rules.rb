module TopologicalInventory
  module Orchestrator
    class TargetedUpdate
      module DestroyActionRules
        def force_destroy_action(target)
          # Set action to :destroy if target doesn't pass
          set_destroy_on_unsupported_source_type(target) &&
            set_destroy_on_availability_status(target) &&
            set_destroy_without_application(target)
        end

        def set_destroy_on_unsupported_source_type(target)
          return if (source_type = target[:source_type]).nil?

          unless source_type.supported_source_type?
            log_msg_for_target(target, "Source Type not supported (#{source_type['name']}), action changed to: 'destroy'", :debug)
            target[:action] = :destroy
            return false
          end
          true
        end

        def set_destroy_on_availability_status(target)
          return if (source = target[:source]).nil?

          if target[:source_type]&.supports_availability_check?
            if source['availability_status'] != 'available'
              log_msg_for_target(target, "Source unavailable (#{source}), action changed to: 'destroy'", :info)
              target[:action] = :destroy
              return false
            end
          end

          true
        end

        def set_destroy_without_application(target)
          if target[:application].blank?
            log_msg_for_target(target, "No supported application for Source (#{target[:source]}), action changed to: 'destroy'", :info)
            target[:action] = :destroy
            return false
          end
          true
        end
      end
    end
  end
end
