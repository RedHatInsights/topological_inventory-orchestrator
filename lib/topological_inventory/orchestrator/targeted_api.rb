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
        filter = make_params_string(filter_key, filter_value)

        topology_source_ids = []
        each_resource(topology_api_url_for("sources?#{filter}"), external_tenant) do |topology_source|
          topology_source_ids << topology_source['id']
        end

        filter = make_params_string(filter_key, topology_source_ids)

        each_resource(sources_api_url_for("sources?#{filter}"), external_tenant) do |source|
          yield source
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

      private

      # @param filter_key [String]
      # @param filter_value [Integer, Array<Integer>]
      def make_params_string(filter_key, filter_value, limit = nil)
        filter = if filter_key.present? && filter_value.present?
                   if filter_value.kind_of?(Array)
                     filter_value.collect { |id| "filter[#{filter_key}][]=#{id}" }.join('&')
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
