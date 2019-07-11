require "manageiq-loggers"

module TopologicalInventory
  module Orchestrator
    class MetricScaler
      attr_reader :logger

      def initialize(logger = nil)
        @logger = logger || ManageIQ::Loggers::CloudWatch.new
      end

      def run
        loop do
          run_once

          sleep 10
        end
      end

      def run_once
        logger.info("#{self.class.name}##{__method__} Starting...")
        object_manager.get_deployment_configs("metric_scaler_enabled=true").each do |dc|
          current_metric_name = dc.metadata.annotations["metric_scaler_current_metric_name"]       # i.e. "topological_inventory_api_puma_busy_threads"
          max_metric_name     = dc.metadata.annotations["metric_scaler_max_metric_name"]           # i.e. "topological_inventory_api_puma_max_threads"
          max_replicas        = dc.metadata.annotations["metric_scaler_max_replicas"]&.to_i        # i.e. "5"
          min_replicas        = dc.metadata.annotations["metric_scaler_min_replicas"]&.to_i        # i.e. "1"
          target_usage_pct    = dc.metadata.annotations["metric_scaler_target_usage_pct"]&.to_i    # i.e. "50"
          scale_threshold_pct = dc.metadata.annotations["metric_scaler_scale_threshold_pct"]&.to_i # i.e. "20"

          next unless current_metric_name && max_metric_name && max_replicas && min_replicas && target_usage_pct && scale_threshold_pct
          logger.info("Metrics scaling enabled for #{dc.metadata.name}")

          endpoint = object_manager.get_endpoint(dc.metadata.name)
          pod_ips  = endpoint.subsets.flat_map { |s| s.addresses.collect { |a| a[:ip] } }

          total_consumed = 0
          total_max      = 0

          pod_ips.each do |ip|
            h = scrape_metrics_from_ip(ip)
            total_consumed += h[current_metric_name].to_f
            total_max      += h[max_metric_name].to_f
          end

          current_usage_pct = (total_consumed.to_f / total_max.to_f) * 100
          deviation_pct = current_usage_pct - target_usage_pct

          logger.info("#{dc.metadata.name} consuming #{total_consumed} of #{total_max}, #{current_usage_pct}%")

          next if deviation_pct.abs < scale_threshold_pct # Within tolerance

          desired_replicas = dc.spec.replicas
          deviation_pct.positive? ? desired_replicas += 1 : desired_replicas -= 1
          desired_replicas = desired_replicas.clamp(min_replicas, max_replicas)

          next if desired_replicas == dc.spec.replicas # already at max or minimum

          logger.info("Scaling #{dc.metadata.name} to #{desired_replicas} replicas")
          object_manager.scale(dc.metadata.name, desired_replicas)
        end
        logger.info("#{self.class.name}##{__method__} Complete")
      end

      private

      def metrics_text_to_h(metrics_scrape)
        metrics_scrape.each_line.with_object({}) do |line, h|
          next if line.start_with?("#") || line.chomp.empty?
          k, v = line.split(" ")
          h[k] = v
        end
      end

      def object_manager
        @object_manager ||= begin
          require "topological_inventory/orchestrator/object_manager"
          ObjectManager.new
        end
      end

      def scrape_metrics_from_ip(ip)
        require 'restclient'
        response = RestClient.get("http://#{ip}:9394/metrics")
        metrics_text_to_h(response)
      end
    end
  end
end
