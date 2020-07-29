require "topological_inventory/orchestrator/targeted_update/api_load_has_one"
require "topological_inventory/orchestrator/targeted_update/api_load_belongs_to"

module TopologicalInventory
  module Orchestrator
    class TargetedUpdate
      include ApiLoadHasOne
      include ApiLoadBelongsTo

      module ApiLoadHelpers
        # API requests:
        # - source type for source
        # - source for endpoint
        # - source for application
        # - endpoint for authentication
        def load_sources_from_targets
          api_load_belongs_to(%i[authentication], :endpoint, 'resource_id')
          api_load_belongs_to(%i[endpoint application], :source, 'source_id')
          api_load_belongs_to(%i[source], :source_type, 'source_type_id')
        end

        # API requests:
        # - supported applications for source
        # Although source has_many applications, finding at least one supported is enough
        def load_applications
          api_load_has_one(:source, :application, 'source_id')
        end

        # API requests: only "create", "update" actions
        # - loads missing endpoints (if event was from Application/Source)
        # - loads missing authentications (if event was from Application/Source/Endpoint)
        # - loads credentials (internal API/authentication)
        def load_credentials_for_upsert
          targets = @targets.select { |target| %i[create update].include?(target[:action]) }

          # Load Endpoint
          api_load_has_one(:source, :endpoint, 'source_id', targets)
          targets = targets.select { |target| target[:endpoint].present? }

          targets.each do |target|
            target[:source].endpoint = target[:endpoint]
          end

          # Load Authentication
          api_load_has_one(:endpoint, :authentication, 'resource_id', targets)
          targets = targets.select { |target| target[:authentication].present? }

          credentials = {}
          targets.each do |target|
            target[:source].authentication = target[:authentication]

            # cache credentials responses
            credentials[target[:authentication]['id']] ||= @api.get_credentials(target[:authentication]['id'], target[:tenant])
            target[:source].credentials = credentials[target[:authentication]['id']]
          end
        end

        def resource_loaded?(target, resource_type)
          if target[resource_type].nil?
            log_msg_for_target(target, "#{resource_type.to_s.titleize} not found")
          end
          target[resource_type].present?
        end

        def source_loaded?(target)
          resource_loaded?(target, :source)
        end

        def source_type_loaded?(target)
          resource_loaded?(target, :source_type)
        end

        def hash_to_api_object(data, dest_model = nil)
          case dest_model
          when :source_type then SourceType.new(data)
          when :source then Source.new(data, data['tenant'], nil, :from_sources_api => true)
          else ApiObject.new(data)
          end
        end
      end
    end
  end
end
