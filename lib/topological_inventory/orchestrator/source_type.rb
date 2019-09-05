require "topological_inventory/orchestrator/api_object"

module TopologicalInventory
  module Orchestrator
    class SourceType < ApiObject
      SUPPORTED_TYPES = %w[amazon ansible-tower azure openshift].freeze
      AVAILABILITY_CHECK_SOURCE_TYPES = %w[amazon ansible-tower openshift].freeze

      def to_s
        attributes['name'] || "Unknown source type: #{attributes.inspect}"
      end

      def sources_per_collector
        return @sources_per_collector if @sources_per_collector.present?

        if attributes['name'].present?
          @sources_per_collector = ::Settings.collectors.sources_per_collector.send(attributes['name']) || 1
        end

        @sources_per_collector
      end

      def collector_definition(collector_image_tag = 'latest')
        if supported_source_type?
          { "image" => "topological-inventory-#{attributes['name']}:#{collector_image_tag}" }
        end
      end

      def supported_source_type?
        attributes['name'].present? && SUPPORTED_TYPES.include?(attributes['name'])
      end

      # Methods amazon? / ansible_tower? / azure? / openshift?
      SUPPORTED_TYPES.each do |type|
        define_method "#{type.sub('-', '_')}?" do
          attributes['name'].to_s == type
        end
      end

      def supports_availability_check?
        AVAILABILITY_CHECK_SOURCE_TYPES.include?(attributes['name'])
      end
    end
  end
end
