require 'topological_inventory/orchestrator/metrics'

module TopologicalInventory
  module Orchestrator
    class Metrics
      class MetricsScaler < TopologicalInventory::Orchestrator::Metrics
        ERROR_COUNTER_MESSAGE = "total number of times the metric_scaler has failed to hit prometheus".freeze

        def configure_metrics
          super
        end

        def default_prefix
          "topological_inventory_metric_scaler_"
        end
      end
    end
  end
end
