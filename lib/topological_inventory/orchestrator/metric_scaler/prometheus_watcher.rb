require "topological_inventory/orchestrator/metric_scaler/watcher"

module TopologicalInventory
  module Orchestrator
    class MetricScaler
      class PrometheusWatcher < Watcher
        METRICS_CHECK_INTERVAL = 150
        METRICS_RANGE          = "10m"
        METRICS_STEP           = "1m"

        def initialize(exporter, deployment_config, deployment_config_name, prometheus_host, logger)
          super(deployment_config, deployment_config_name, logger)
          @prometheus_host = prometheus_host
          @prometheus = exporter
          @scaling_allowed.value = false
        end

        def configured?
          @query && @max_replicas && @min_replicas && @target_usage && @scale_threshold
        end

        def configure
          @max_replicas        = deployment_config.metadata.annotations["metric_scaler_max_replicas"]&.to_i    # i.e. "5"
          @min_replicas        = deployment_config.metadata.annotations["metric_scaler_min_replicas"]&.to_i    # i.e. "1"
          @target_usage        = deployment_config.metadata.annotations["metric_scaler_target_usage"]&.to_f    # i.e. "50"
          @scale_threshold     = deployment_config.metadata.annotations["metric_scaler_scale_threshold"]&.to_f # i.e. "20"
          @query               = deployment_config.metadata.annotations["metric_scaler_prometheus_query"]      # i.e. any query that outputs a single number showing load. Preferably at a 1 minute resolution.
        end

        def start
          @thread = Thread.new do
            logger.info("Watcher thread for #{deployment_config_name} starting")
            until finished?
              new_metrics = download_metrics
              if new_metrics.present?
                new_metrics.each do |time_value_pair|
                  metrics << time_value_pair[1].to_f
                end

                if metrics.average > @scale_threshold
                  @scaling_allowed.value = true
                end
              end

              sleep METRICS_CHECK_INTERVAL
            end
            logger.info("Watcher thread for #{deployment_config_name} stopping")
          end
        end

        def download_metrics
          full_url = File.join(prometheus_url, promql_query)
          response = RestClient.get(full_url, {:accept => :json})

          body = JSON.parse(response.body)
          raise response.body unless body['status'] == 'success'

          metrics = body.dig('data', 'result').to_a.first
          if metrics.blank?
            logger.warn("PrometheusWatcher: Empty result from Prometheus received")
          end
          metrics.to_a
        rescue RestClient::BadRequest => e
          logger.error("PrometheusWatcher: Bad request: #{e.response.body}")
          @prometheus.record_metric_scaler_error
          []
        rescue RestClient::ExceptionWithResponse => e
          logger.error("PrometheusWatcher: RestClient error: #{e.message}")
          @prometheus.record_metric_scaler_error
          []
        rescue => e
          logger.error("PrometheusWatcher: #{e.message}\n#{e.backtrace.join("\n")}")
          @prometheus.record_metric_scaler_error
          []
        end

        def scale_to_desired_replicas
          super if scaling_allowed?
          @scaling_allowed.value = false
        end

        private

        def desired_replicas
          avg_consumer_lag = metrics.average
          return deployment_config.spec.replicas if avg_consumer_lag.to_i.zero? # No Data

          super
        end

        def prometheus_url
          @prometheus_host = "http://#{@prometheus_host}" unless @prometheus_host =~ %r{\Ahttps?:\/\/}
          uri = URI(@prometheus_host)
          uri.path = default_api_path if uri.path.blank?
          uri.to_s
        end

        def default_api_path
          "/api/v1".freeze
        end

        def promql_query
          query = "query?query=(#{@query.gsub(" ","")})"
          query += "[#{METRICS_RANGE}:#{METRICS_STEP}]"
        end
      end
    end
  end
end
