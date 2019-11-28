require "topological_inventory/orchestrator/logger"

module TopologicalInventory
  module Orchestrator
    class Api
      include Logging

      attr_accessor :sources_api, :sources_internal_api, :topology_api, :topology_internal_api

      def initialize(sources_api:, topology_api:)
        self.sources_api = sources_api
        self.sources_internal_api = URI.parse(sources_api).tap { |uri| uri.path = "/internal/v1.0" }.to_s

        self.topology_api = topology_api
        self.topology_internal_api = URI.parse(topology_api).tap { |uri| uri.path = "/internal/v1.0" }.to_s
      end

      def each_tenant
        each_resource(topology_internal_url_for("tenants")) { |tenant| yield tenant }
      end

      def each_source_type
        each_resource(sources_api_url_for("source_types")) { |source_type| yield source_type }
      end

      def each_source
        each_tenant do |tenant|
          tenant_name = tenant["external_tenant"]
          # Query applications for the supported application_types, then later we can check if the source
          # has any supported applications from this hash
          applications_by_source_id = each_resource(supported_applications_url, tenant_name).group_by { |application| application["source_id"] }

          each_resource(topology_api_url_for("sources"), tenant_name) do |topology_source|
            source = get_and_parse(sources_api_url_for("sources", topology_source["id"].to_s), tenant_name)

            if source.present?
              applications_for_source = applications_by_source_id[source["id"]]
              yield source, tenant_name if applications_for_source.present?
            end
          end
        end
      end

      def each_application_type
        each_resource(sources_api_url_for("application_types"))
      end

      def get_endpoint(source_id, tenant)
        endpoints = get_and_parse(sources_api_url_for("sources", source_id, "endpoints"), tenant)
        endpoints&.dig("data")&.first
      end

      def get_authentication(endpoint_id, tenant)
        authentications = get_and_parse(sources_api_url_for("endpoints", endpoint_id, "authentications"), tenant)
        authentications&.dig("data")&.first
      end

      def get_credentials(authentication_id, tenant)
        get_and_parse(sources_internal_url_for("/authentications/#{authentication_id}?expose_encrypted_attribute[]=password"), tenant)
      end

      def update_topological_inventory_source_refresh_status(source, refresh_status)
        RestClient.patch(
          topology_internal_url_for("sources", source["id"]),
          {:refresh_status => refresh_status}.to_json,
          tenant_header(source["tenant"])
        )
      rescue StandardError => e
        logger.error("Failed to update 'refresh_status' on source #{source["id"]}\n#{e.message}\n#{e.backtrace.join("\n")}")
      end

      private

      def each_resource(url, tenant_account = Worker::ORCHESTRATOR_TENANT, &block)
        return enum_for(:each_resource, url, tenant_account) unless block_given?
        return if url.nil?

        response = get_and_parse(url, tenant_account)
        paging = response.kind_of?(Hash)

        resources = paging ? response["data"] : response
        resources&.each { |i| yield i }

        return unless paging

        next_page_link = response.fetch_path("links", "next")
        return unless next_page_link

        next_url = URI.parse(url).merge(next_page_link).to_s

        each_resource(next_url, tenant_account, &block)
      end

      def sources_api_url_for(*path)
        File.join(sources_api, *path)
      end

      def sources_internal_url_for(*path)
        File.join(sources_internal_api, *path)
      end

      def topology_api_url_for(*path)
        File.join(topology_api, *path)
      end

      def topology_internal_url_for(*path)
        File.join(topology_internal_api, *path)
      end

      def get_and_parse(url, tenant_account = Worker::ORCHESTRATOR_TENANT)
        JSON.parse(
          RestClient.get(url, tenant_header(tenant_account))
        )
      rescue RestClient::NotFound
        nil
      rescue RestClient::Exception => e
        logger.error("Failed to get #{url}: #{e}")
        raise
      end

      def tenant_header(tenant_account)
        {"x-rh-identity" => Base64.strict_encode64({"identity" => {"account_number" => tenant_account}}.to_json)}
      end

      # Set of ids for supported applications
      def supported_application_type_ids
        topology_app_name = "/insights/platform/topological-inventory"

        each_application_type.select do |application_type|
          application_type["name"] == topology_app_name || application_type["dependent_applications"]&.include?(topology_app_name)
        end.map do |application_type|
          application_type["id"]
        end
      end

      # URL to get a list of applications for supported application types
      def supported_applications_url
        query = URI.escape(supported_application_type_ids.map { |id| "filter[application_type_id][eq][]=#{id}" }.join("&"))
        sources_api_url_for("applications?#{query}")
      end
    end
  end
end
