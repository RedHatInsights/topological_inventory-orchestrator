require "manageiq-loggers"

module TopologicalInventory
  module Orchestrator
    class MetricScaler
      attr_reader :logger

      def initialize(logger = nil)
        require "topological_inventory/orchestrator/metric_scaler/watcher"
        @logger = logger || ManageIQ::Loggers::CloudWatch.new
        @cache  = {}
      end

      def run
        loop do
          run_once

          sleep 10
        end
      end

      def run_once
        logger.info("#{self.class.name}##{__method__} Starting...")
        dc_names = object_manager.get_deployment_configs("metric_scaler_enabled=true").collect { |dc| dc.metadata.name }

        # newly_configured
        (dc_names - @cache.keys).each { |name| @cache[name] = Watcher.new(name, logger).tap(&:start) }
        # no_longer_configured
        (@cache.keys - dc_names).each { |name| @cache.delete(name).stop }
        # currently configured
        dc_names.each                 { |name| @cache[name].scale_to_desired_replicas }

        logger.info("#{self.class.name}##{__method__} Complete")
      end

      private

      def object_manager
        @object_manager ||= begin
          require "topological_inventory/orchestrator/object_manager"
          ObjectManager.new
        end
      end
    end
  end
end
