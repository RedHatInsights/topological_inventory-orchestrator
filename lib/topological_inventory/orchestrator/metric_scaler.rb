require "manageiq-loggers"
require "topological_inventory/orchestrator/object_manager"
require "topological_inventory/orchestrator/metric_scaler/watcher"
require "topological_inventory/orchestrator/metric_scaler/persister_watcher"

module TopologicalInventory
  module Orchestrator
    class MetricScaler
      attr_reader :logger

      def initialize(thanos_hostname, persister_promql_namespace, logger = nil)
        @logger = logger || ManageIQ::Loggers::CloudWatch.new
        @thanos_hostname = thanos_hostname
        @persister_promql_namespace = persister_promql_namespace
        @cache  = {}
      end

      def run
        logger.info("#{self.class.name}##{__method__} Starting...")
        loop do
          run_once

          sleep 10
        end
        logger.info("#{self.class.name}##{__method__} Complete")
      end

      def run_once
        dc_names = object_manager.get_deployment_configs("metric_scaler_enabled=true").collect { |dc| dc.metadata.name }

        # newly_configured
        (dc_names - @cache.keys).each { |name| @cache[name] = watcher_by_name(name).tap(&:start) }
        # no_longer_configured
        (@cache.keys - dc_names).each { |name| @cache.delete(name).stop }
        # currently configured
        dc_names.each                 { |name| @cache[name].scale_to_desired_replicas if @cache[name].scaling_allowed? }
      end

      private

      def watcher_by_name(dc_name)
        if dc_name.include?('topological-inventory-persister')
          PersisterWatcher.new(dc_name, @thanos_hostname, @persister_promql_namespace, logger)
        else
          Watcher.new(dc_name, logger)
        end
      end

      def object_manager
        @object_manager ||= ObjectManager.new
      end
    end
  end
end
