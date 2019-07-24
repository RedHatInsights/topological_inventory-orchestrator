module TopologicalInventory
  module Orchestrator
    class MetricScaler
      class Watcher
        attr_reader :deployment_config, :deployment_config_name, :logger, :thread

        def initialize(deployment_config_name, logger)
          @deployment_config_name = deployment_config_name
          @logger = logger
          logger.info("Metrics scaling enabled for #{deployment_config_name}")
          configure
        end

        def configured?
          @current_metric_name && @max_metric_name && @max_replicas && @min_replicas && @target_usage_pct && @scale_threshold_pct
        end

        def start
          @thread = Thread.new do
            logger.info("Watcher thread for #{deployment_config_name} starting")
            loop do
              configure
              break unless configured?

              60.times do # Collect metrics for ~1 minute then check for config changes
                moving_usage << percent_usage_from_metrics
                sleep 1
              end
            end
            logger.info("Watcher thread for #{deployment_config_name} stopping")
          end
        end

        def stop
          @thread.exit
          @thread.join
        end

        def scale_to_desired_replicas
          return unless configured?

          desired_count = desired_replicas

          return if desired_count == deployment_config.spec.replicas # already at max or minimum

          logger.info("Scaling #{deployment_config_name} to #{desired_count} replicas")
          object_manager.scale(deployment_config_name, desired_count)

          # Wait for scaling to complete in Openshift
          sleep(1) until pod_ips.length == desired_count
          logger.info("Scaling #{deployment_config_name} complete")
        end

        private

        def moving_usage
          @moving_usage ||= begin
            require "topological_inventory/orchestrator/fixed_length_array"
            TopologicalInventory::Orchestrator::FixedLengthArray.new(60)
          end
        end

        def configure
          logger.info("Fetching configuration for #{deployment_config_name}")
          @deployment_config   = object_manager.get_deployment_config(deployment_config_name)
          @current_metric_name = deployment_config.metadata.annotations["metric_scaler_current_metric_name"]       # i.e. "topological_inventory_api_puma_busy_threads"
          @max_metric_name     = deployment_config.metadata.annotations["metric_scaler_max_metric_name"]           # i.e. "topological_inventory_api_puma_max_threads"
          @max_replicas        = deployment_config.metadata.annotations["metric_scaler_max_replicas"]&.to_i        # i.e. "5"
          @min_replicas        = deployment_config.metadata.annotations["metric_scaler_min_replicas"]&.to_i        # i.e. "1"
          @target_usage_pct    = deployment_config.metadata.annotations["metric_scaler_target_usage_pct"]&.to_i    # i.e. "50"
          @scale_threshold_pct = deployment_config.metadata.annotations["metric_scaler_scale_threshold_pct"]&.to_i # i.e. "20"
        end

        def desired_replicas
          deviation = moving_usage.average.to_f - @target_usage_pct
          count     = deployment_config.spec.replicas

          return count if deviation.abs < @scale_threshold_pct # Within tolerance

          deviation.positive? ? count += 1 : count -= 1
          count.clamp(@min_replicas, @max_replicas)
        end

        def pod_ips
          endpoint = object_manager.get_endpoint(deployment_config_name)
          endpoint.subsets.flat_map { |s| s.addresses.collect { |a| a[:ip] } }
        end

        def object_manager
          @object_manager ||= begin
            require "topological_inventory/orchestrator/object_manager"
            ObjectManager.new
          end
        end

        ### Metrics scraping

        def metrics_text_to_h(metrics_scrape)
          metrics_scrape.each_line.with_object({}) do |line, h|
            next if line.start_with?("#") || line.chomp.empty?

            k, v = line.split(" ")
            h[k] = v
          end
        end

        def percent_usage_from_metrics
          total_consumed = total_max = 0.0

          pod_ips.each do |ip|
            metrics = scrape_metrics_from_ip(ip)
            next if metrics[@max_metric_name].to_f == 0.0 # Hasn't handled any traffic yet, so metric isn't even initialized

            total_consumed += metrics[@current_metric_name].to_f
            total_max      += metrics[@max_metric_name].to_f
          end

          ((total_consumed.to_f / total_max.to_f) * 100).tap do |current_usage_pct|
            logger.info("#{deployment_config_name} consuming #{total_consumed} of #{total_max}, #{current_usage_pct}%")
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
end
