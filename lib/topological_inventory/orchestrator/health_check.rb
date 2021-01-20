module TopologicalInventory
  module Orchestrator
    class HealthCheck
      include Logging

      attr_accessor :sources_api, :topology_api, :k8s, :interval

      def initialize(sources_api, topology_api, k8s, interval)
        @sources_api = sources_api
        @topology_api = topology_api
        @k8s = k8s
        @interval = interval
      end

      def run
        loop do
          checks

          sleep interval
        end
      end

      def checks
        errors = []

        errors << check_url(topology_api)
        errors << check_url(sources_api)
        errors << check_k8s(k8s)

        if errors.any?
          FileUtils.rm_f("/tmp/healthy")
        else
          FileUtils.touch("/tmp/healthy")
        end
      end

      private

      def check_url(uri)
        logger.info("[HealthCheck] Checking URL: #{uri}")

        resp = Net::HTTP.get_response(uri.host, "/health", uri.port)
        # Checking if the response code is 400 or larger
        # this is the exact same behavior as OCP's http livenessProbe
        raise if resp.code.to_i >= 400
      rescue
        logger.warn("[HealthCheck] Failed URL: #{uri}")
        :error
      end

      def check_k8s(k8s)
        logger.info("[HealthCheck] Checking k8s: #{k8s.send(:connection).api_endpoint}")

        raise if k8s.check_api_status.nil?
      rescue
        logger.warn("[HealthCheck] k8s failing")
        :error
      end
    end
  end
end
