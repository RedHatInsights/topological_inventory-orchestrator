require "topological_inventory/orchestrator/metric_scaler/watcher"
require "pry-byebug"

module TopologicalInventory
  module Orchestrator
    class MetricScaler
      class PersisterWatcher < Watcher
        METRICS_STEP           = 30
        METRICS_CHECK_INTERVAL = 150
        METRICS_RANGE          = 300

        def initialize(deployment_config_name, thanos_hostname, logger)
          super(deployment_config_name, logger)
          @thanos_hostname = thanos_hostname
          @scaling_allowed.value = false
        end

        def configured?
          true
        end

        def configure
          @deployment_config  = object_manager.get_deployment_config(deployment_config_name)
          @min_replicas       = 1
          @max_replicas       = 10
          @scale_threshold    = 25 # threshold for scaling
          @target_usage       = 50 # target queue depth
        end

        def start
          @thread = Thread.new do
            logger.info("Watcher thread for #{deployment_config_name} starting")
            until finished?
              download_metrics.each do |time_value_pair|
                metrics << time_value_pair[1]
              end

              @scaling_allowed.value = true

              sleep METRICS_CHECK_INTERVAL
            end
            logger.info("Watcher thread for #{deployment_config_name} stopping")
          end
        end

        def download_metrics
          full_url = File.join(thanos_api_url, promql_query)
          response = RestClient.get(full_url, {:accept => :json})

          body = JSON.parse(response.body)
          raise response.body unless body['status'] == 'success'

          metrics = body.dig('data', 'result').to_a.first
          if metrics.blank?
            logger.warn("PersisterWatcher: Empty result from Thanos received")
          end
          metrics.to_a
        rescue RestClient::BadRequest => e
          logger.error("PersisterWatcher: Bad request: #{e.response.body}")
          []
        rescue RestClient::ExceptionWithResponse => e
          logger.error("PersisterWatcher: RestClient error: #{e.message}")
          []
        rescue => e
          logger.error("PersisterWatcher: #{e.message}\n#{e.backtrace.join("\n")}")
          []
        end

        def scale_to_desired_replicas
          super
          @scaling_allowed.value = false
        end

        private

        def desired_replicas
          avg_consumer_lag = metrics.average
          return deployment_config.spec.replicas if avg_consumer_lag.to_i.zero? # Thanos doesn't have data

          super
        end

        def max_metrics_count
          METRICS_RANGE / METRICS_STEP
        end

        def thanos_api_url
          @thanos_hostname = "http://#{@thanos_hostname}" unless @thanos_hostname =~ %r{\Ahttps?:\/\/}
          uri = URI(@thanos_hostname)
          uri.path = default_api_path if uri.path.blank?
          uri.to_s
        end

        def default_api_path
          "/api/v1".freeze
        end

        def promql_query
          query = "query_range?query=sum(kafka_consumergroup_group_lag{topic=~'platform.topological-inventory.persister'}) by (group, topic)"
          query += "&start=#{(Time.now.utc - METRICS_RANGE).strftime("%Y-%m-%dT%H:%M:%S.%LZ")}" # RFC 3339
          query += "&end=#{(Time.now.utc).strftime("%Y-%m-%dT%H:%M:%S.%LZ")}" # RFC 3339
          query += "&step=#{METRICS_STEP.to_f}"
        end
      end
    end
  end
end
