require 'topological_inventory/orchestrator/metrics'

module TopologicalInventory
  module Orchestrator
    class Metrics
      class Orchestrator < TopologicalInventory::Orchestrator::Metrics
        ERROR_TYPES = %i[api event_manager secret quota_error].freeze

        def record_event(event_name)
          @events_counter&.observe(1, :event_name => event_name.to_s)
        end

        def record_config_maps(opt = :set, value: nil, source_type: :unknown)
          record_gauge(@config_maps_gauge, opt, :value => value, :labels => {:source_type => source_type.to_s})
        end

        def record_deployment_configs(opt = :set, value: nil, source_type: :unknown)
          record_gauge(@deployments_gauge, opt, :value => value, :labels => {:source_type => source_type.to_s})
        end

        def record_secrets(opt = :set, value: nil, source_type: :unknown)
          record_gauge(@secrets_gauge, opt, :value => value, :labels => {:source_type => source_type.to_s})
        end

        def record_services(opt = :set, value: nil, source_type: :unknown)
          record_gauge(@services_gauge, opt, :value => value, :labels => {:source_type => source_type.to_s})
        end

        def configure_metrics
          super

          @config_maps_gauge = PrometheusExporter::Metric::Gauge.new("config_maps", 'number of active collector config maps')
          @deployments_gauge = PrometheusExporter::Metric::Gauge.new("deployment_configs", 'number of active collector deployment configs')
          @events_counter = PrometheusExporter::Metric::Counter.new("events_count", "total number of received events")
          @secrets_gauge = PrometheusExporter::Metric::Gauge.new("secrets", 'number of active collector secrets')
          @services_gauge = PrometheusExporter::Metric::Gauge.new("services", 'number of active collector services')

          @server.collector.register_metric(@events_counter)
          @server.collector.register_metric(@config_maps_gauge)
          @server.collector.register_metric(@deployments_gauge)
          @server.collector.register_metric(@secrets_gauge)
          @server.collector.register_metric(@services_gauge)
        end

        def default_prefix
          "topological_inventory_orchestrator_"
        end
      end
    end
  end
end
