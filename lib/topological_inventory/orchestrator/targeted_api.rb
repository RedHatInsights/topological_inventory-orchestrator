require "topological_inventory/orchestrator/api"

module TopologicalInventory
  module Orchestrator
    class TargetedApi < Api
      def each_source_type(_external_tenant = nil, filter_key: nil, filter_value: nil)
        filter = make_params_string(filter_key, filter_value)

        each_resource(sources_api_url_for("source_types?#{filter}")) do |source_type|
          yield source_type
        end
      end

      def each_source(external_tenant = nil, filter_key: nil, filter_value: nil, limit: nil)
        filter = make_params_string(filter_key, filter_value, limit)

        topology_source_ids = []
        each_resource(topology_api_url_for("sources?#{filter}"), external_tenant) do |topology_source|
          topology_source_ids << topology_source['id']
        end

        if topology_source_ids.present?
          filter = make_params_string(filter_key, topology_source_ids)

          each_resource(sources_api_url_for("sources?#{filter}"), external_tenant) do |source|
            yield source
          end
        end
      end

      def each_endpoint(external_tenant = nil, filter_key: nil, filter_value: nil, limit: nil)
        filter = make_params_string(filter_key, filter_value, limit)

        each_resource(sources_api_url_for("endpoints?#{filter}"), external_tenant) do |endpoint|
          yield endpoint
        end
      end

      def each_authentication(external_tenant = nil, filter_key: nil, filter_value: nil, limit: nil)
        filter = make_params_string(filter_key, filter_value, limit)

        # Hardcoded
        filter = "filter[resource_type]=Endpoint&#{filter}" if filter_key == 'resource_id'

        each_resource(sources_api_url_for("authentications?#{filter}"), external_tenant) do |authentication|
          yield authentication
        end
      end

      def each_application(external_tenant = nil, filter_key: nil, filter_value: nil, limit: nil)
        filter = make_params_string(filter_key, filter_value, limit)
        app_type_filter = supported_application_type_ids.map { |id| "filter[application_type_id][eq][]=#{id}" }.join("&")
        filter = filter.blank? ? app_type_filter : "#{filter}&#{app_type_filter}"

        each_resource(sources_api_url_for("applications?#{filter}"), external_tenant) do |app|
          yield app
        end
      end

      private

      # @param filter_key [String]
      # @param filter_value [Integer, Array<Integer>]
      def make_params_string(filter_key, filter_value, limit = nil)
        filter = if filter_key.present? && filter_value.present?
                   if filter_value.kind_of?(Array) && filter_value.size > 1
                     filter_value.collect { |id| "filter[#{filter_key}][]=#{id}" }.join('&')
                   elsif filter_value.kind_of?(Array) && filter_value.size == 1
                     "filter[#{filter_key}]=#{filter_value.first}"
                   else
                     "filter[#{filter_key}]=#{filter_value}"
                   end
                 end
        filter += "#{'&' if filter.present?}limit=#{limit}" if limit
        filter
      end
    end
  end
end
