require "topological_inventory/orchestrator/openshift_object"

module TopologicalInventory
  module Orchestrator
    # Service is maintained by config map
    # Paired by LABEL_UNIQUE label
    class Service < OpenshiftObject
      LABEL_COMMON = "tp-inventory/collectors-service".freeze
      LABEL_UNIQUE = "tp-inventory/config-uid".freeze

      attr_accessor :config_map

      def to_s
        uid
      end

      def create_in_openshift
        logger.info("Creating Service #{self}")
        raise "Cannot create service, no config map associated" if config_map.nil?

        object_manager.create_service(name, source_type_name) do |service|
          service[:metadata][:labels][LABEL_UNIQUE] = uid
          service[:metadata][:labels][LABEL_COMMON] = ::Settings.labels.version.to_s
          service[:metadata][:labels][ConfigMap::LABEL_SOURCE_TYPE] = config_map.source_type['name'] if config_map.source_type.present?
        end

        logger.info("[OK] Created Service #{self}")
      end

      def update!
        # noop
      end

      # Targeted update
      def upsert_one!(source)
        # noop
      end

      def targeted_delete(source)
        # noop
      end

      def delete_in_openshift
        logger.info("Deleting Service #{self}")

        object_manager.delete_service(name, source_type_name)

        logger.info("[OK] Deleted Service #{self}")
      end

      def name
        source_type = config_map&.source_type
        type_name   = source_type.present? ? source_type['name'] : 'unknown'
        "service-#{type_name}-#{uid}"
      end

      # Service config-UID is relation to config-map's template
      def uid
        return @uid if @uid.present?

        @uid = if @openshift_object.present? # no openshift_object reloading here (cycle)
                 @openshift_object.metadata.labels[LABEL_UNIQUE]
               else
                 config_map&.uid
               end
      end

      private

      def save_service
        object_manager.update_service(openshift_object)
        openshift_object(:reload => true)
      end

      def load_openshift_object
        object_manager.get_services(LABEL_COMMON).detect { |s| s.metadata.labels[LABEL_UNIQUE] == uid }
      end

      def source_type_name
        config_map&.source_type.try(:[], 'name') || 'unknown'
      end
    end
  end
end
