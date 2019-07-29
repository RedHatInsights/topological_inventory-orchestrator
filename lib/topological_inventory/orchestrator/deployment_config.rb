require "topological_inventory/orchestrator/openshift_object"

module TopologicalInventory
  module Orchestrator
    # Deployment config is maintained by config map
    # Paired by LABEL_UNIQUE label
    class DeploymentConfig < OpenshiftObject
      LABEL_COMMON = "tp-inventory/collector".freeze
      LABEL_DIGEST = "topological-inventory/collector_digest".freeze # single-source DCs
      LABEL_UNIQUE = "tp-inventory/config-uid".freeze

      attr_accessor :config_map

      def to_s
        uid
      end

      def create_in_openshift
        raise "Cannot create deployment config, no config map associated" if config_map.nil?

        # Gets image name (defined per source type => same for all sources in config_map)
        related_source = config_map.sources.detect { |source| source.from_sources_api }
        if related_source.nil?
          # This state can happen when someone deletes DC manually
          #   and all Sources in ConfigMap are marked for deletion
          logger.warn("Failed to create deployment config, no existing source associated")
          return
        end
        image = related_source.collector_definition["image"]

        logger.info("Creating DeploymentConfig #{self}")
        object_manager.create_deployment_config(name, ENV["IMAGE_NAMESPACE"], image) do |dc|
          dc[:metadata][:labels][LABEL_UNIQUE] = uid
          dc[:metadata][:labels][LABEL_COMMON] = "true"
          dc[:metadata][:labels][ConfigMap::LABEL_SOURCE_TYPE] = config_map.source_type['name'] if config_map.source_type.present?
          dc[:spec][:replicas] = 1

          volumes = dc[:spec][:template][:spec][:volumes]
          volumes << {
            :name      => 'sources-config',
            :configMap => {:name => config_map.name}
          }

          volumes << {
            :name   => 'sources-secrets',
            :secret => {
              :secretName => config_map.secret&.name
            }
          }

          container = dc[:spec][:template][:spec][:containers].first
          container[:volumeMounts] = []
          container[:volumeMounts] << {
            :name => 'sources-config',
            :mountPath => "/opt/#{config_map.source_type['name']}-collector/config"
          }

          container[:volumeMounts] << {
            :name => 'sources-secrets',
            :mountPath => "/opt/#{config_map.source_type['name']}-collector/secret"
          }
          # Environment variables
          container[:env] = container_env_values
        end
        logger.info("[OK] Created DeploymentConfig #{self}")
      end

      def delete_in_openshift
        logger.info("Deleting DeploymentConfig #{self}")

        object_manager.delete_deployment_config(name)

        logger.info("[OK] Deleted DeploymentConfig #{self}")
      end

      # DC config-UID is relation to config-map's template
      def uid
        return @uid if @uid.present?

        @uid = if @openshift_object.present? # no openshift_object reloading here (cycle)
                 @openshift_object.metadata.labels[LABEL_UNIQUE]
               else
                 config_map&.uid
               end
      end

      def name
        "tp-inventory-collector-#{uid}"
      end

      private

      def container_env_values
        [
          { :name => "INGRESS_API", :value => "http://#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_HOST"]}:#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_PORT"]}" },
          { :name => "CONFIG", :value => 'custom'}
        ]
      end

      def load_openshift_object
        object_manager.get_deployment_configs(LABEL_COMMON).detect { |s| s.metadata.labels[LABEL_UNIQUE] == uid }
      end
    end
  end
end
