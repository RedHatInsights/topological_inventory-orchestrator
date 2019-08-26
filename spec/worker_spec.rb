describe TopologicalInventory::Orchestrator::Worker do
  let(:tenants_response) do
    <<~EOJ
      {
        "links": {},
        "data": [
          {
            "id": "1",
            "external_tenant": "#{user_tenant_account}"
          }
        ]
      }
    EOJ
  end

  let(:orchestrator_tenant_header) do
    {"x-rh-identity" => "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6InN5c3RlbV9vcmNoZXN0cmF0b3IifX0="}
  end

  let(:user_tenant_account) { "12345" }

  let(:user_tenant_header) do
    {"x-rh-identity" => "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjEyMzQ1In19"}
  end

  around do |e|
    ENV["IMAGE_NAMESPACE"] = "buildfactory"
    e.run
    ENV.delete("IMAGE_NAMESPACE")
  end

  subject { described_class.new(collector_image_tag: "dev", sources_api: sources_api, topology_api: topology_api) }

  let(:sources_api)  { "http://sources.local:8080/api/sources/v1.0" }
  let(:topology_api) { "http://topology.local:8080/api/topological-inventory/v0.1" }

  context "#collectors_from_sources_api" do
    let(:source_types_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","name":"openshift","product_name":"OpenShift","vendor":"Red Hat"},
            {"id":"2","name":"amazon","product_name":"Amazon AWS","vendor":"Amazon"}
          ]
        }
      EOJ
    end

    let(:application_types_response) do
      <<~EOJ
        {
          "data": [
            {
                "dependent_applications": ["/insights/platform/topological-inventory"],
                "display_name": "Catalog",
                "id": "1",
                "name": "/insights/platform/catalog",
                "supported_authentication_types": {"ansible_tower": ["username_password"]},
                "supported_source_types": ["ansible_tower"]
            },
            {
                "dependent_applications": [],
                "display_name": "Cost Management",
                "id": "2",
                "name": "/insights/platform/cost-management",
                "supported_authentication_types": {"amazon": ["arn"]},
                "supported_source_types": ["amazon"]
            },
            {
                "dependent_applications": [],
                "display_name": "Topological Inventory",
                "id": "3",
                "name": "/insights/platform/topological-inventory",
                "supported_authentication_types": {
                    "amazon": ["access_key_secret_key"],
                    "ansible_tower": ["username_password"],
                    "azure": ["username_password"],
                    "openshift": ["token"]
                },
                "supported_source_types": ["amazon", "ansible_tower", "azure", "openshift"]
            }
          ],
          "links": {
          }
        }
      EOJ
    end

    let(:applications_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","application_type_id":"1","source_id":"1","tenant_id":"1"},
            {"id":"2","application_type_id":"1","source_id":"2","tenant_id":"1"}
          ]
        }
      EOJ
    end

    let(:topology_sources_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","uid":"cacebc33-1ed8-49d4-b4f9-713f2552ee65","tenant_id":"1"},
            {"id":"2","uid":"31b5338b-685d-4056-ba39-d00b4d7f19cc","tenant_id":"1"},
            {"id":"3","uid":"95f057b7-ec11-4f04-b155-e54dcd5b01aa","tenant_id":"1"},
            {"id":"4","uid":"2c187e9b-7442-474c-bdc4-da47bf9553fc","tenant_id":"1"}
          ]
        }
      EOJ
    end

    let(:sources_1_response) do
      <<~EOJ
        {
          "id":"1","source_type_id":"1","name":"mock-source","uid":"cacebc33-1ed8-49d4-b4f9-713f2552ee65","tenant":"#{user_tenant_account}"
        }
      EOJ
    end

    let(:sources_2_response) do
      <<~EOJ
        {
          "id":"2","source_type_id":"1","name":"OCP","uid":"31b5338b-685d-4056-ba39-d00b4d7f19cc","tenant":"#{user_tenant_account}"
        }
      EOJ
    end

    let(:sources_3_response) do
      <<~EOJ
        {
          "id":"3","source_type_id":"2","name":"AWS","uid":"95f057b7-ec11-4f04-b155-e54dcd5b01aa","tenant":"#{user_tenant_account}"
        }
      EOJ
    end

    let(:sources_1_endpoints_response) { {"links" => {}, "data" => []}.to_json }

    let(:sources_2_endpoints_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","default":true,"host":"example.com","path":"/api","port":8443,"scheme":"https","source_id":"2","tenant_id":"1","role":"default"},
            {"id":"8","default":true,"host":"example.com","path":"/api","port":8443,"scheme":"https","source_id":"2","tenant_id":"1","role":"nothing"},
            {"id":"9","default":true,"host":"example.com","path":"/api","port":8443,"scheme":"https","source_id":"2","tenant_id":"1"}
          ]
        }
      EOJ
    end

    let(:endpoints_1_authentications_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","authtype":"default"}
          ]
        }
      EOJ
    end

    let(:endpoints_8_authentications_response) do
      <<~EOJ
        {
          "links": {},
          "data": []
        }
      EOJ
    end

    it "generates the expected hash" do
      stub_rest_get("#{sources_api}/source_types", orchestrator_tenant_header, source_types_response)

      stub_rest_get("#{sources_api}/application_types", orchestrator_tenant_header, application_types_response)
      stub_rest_get("http://topology.local:8080/internal/v1.0/tenants", orchestrator_tenant_header, tenants_response)

      application_query = "filter[application_type_id][eq][]=1&filter[application_type_id][eq][]=3"
      stub_rest_get("#{sources_api}/applications?#{application_query}", user_tenant_header, applications_response)
      stub_rest_get("#{topology_api}/sources", user_tenant_header, topology_sources_response)

      stub_rest_get("#{sources_api}/sources/1", user_tenant_header, sources_1_response)
      stub_rest_get("#{sources_api}/sources/1/endpoints", user_tenant_header, sources_1_endpoints_response)

      stub_rest_get("#{sources_api}/sources/2", user_tenant_header, sources_2_response)
      stub_rest_get("#{sources_api}/sources/2/endpoints", user_tenant_header, sources_2_endpoints_response)
      stub_rest_get("#{sources_api}/endpoints/1/authentications", user_tenant_header, endpoints_1_authentications_response)
      stub_rest_get("http://sources.local:8080/internal/v1.0/authentications/1?expose_encrypted_attribute[]=password", user_tenant_header, {"username" => "USER", "password" => "PASS"}.to_json)

      stub_rest_get("#{sources_api}/sources/3", user_tenant_header, sources_3_response)

      stub_rest_get_404("#{sources_api}/sources/4", user_tenant_header)

      expect(RestClient).not_to receive(:get).with("#{sources_api}/endpoints/8/authentications", any_args)
      expect(RestClient).not_to receive(:get).with("#{sources_api}/endpoints/9/authentications", any_args)
      expect(RestClient).not_to receive(:get).with("http://sources.local:8080/internal/v1.0/authentications/8?expose_encrypted_attribute[]=password", any_args)
      expect(RestClient).not_to receive(:get).with("http://sources.local:8080/internal/v1.0/authentications/9?expose_encrypted_attribute[]=password", any_args)

      collector_hash = subject.send(:collectors_from_sources_api)

      expect(collector_hash).to eq(
        "98d6f0dbd5219b970d6161fcd1c4d0284fa51d48" => {
          "endpoint_host"   => "example.com",
          "endpoint_path"   => "/api",
          "endpoint_port"   => "8443",
          "endpoint_scheme" => "https",
          "image"           => "topological-inventory-openshift:dev",
          "image_namespace" => "buildfactory",
          "source_id"       => "2",
          "source_uid"      => "31b5338b-685d-4056-ba39-d00b4d7f19cc",
          "secret"          => {
            "password" => "PASS",
            "username" => "USER"
          },
          "tenant"          => user_tenant_account,
        }
      )
    end
  end

  describe "#internal_url_for" do
    it "replaces the path with /internal/v0.1/<path>" do
      expect(subject.send(:topology_internal_url_for, "the/best/path")).to eq("http://topology.local:8080/internal/v1.0/the/best/path")
    end
  end

  describe "#each_resource" do
    let(:path_1) { "/api/topological-inventory/v1.0/some_collection" }
    let(:path_2) { "/api/topological-inventory/v1.0/some_collection?offset=10&limit=10" }
    let(:path_3) { "/api/topological-inventory/v1.0/some_collection?offset=20&limit=10" }
    let(:url_1) { "http://example.com:8080#{path_1}" }
    let(:url_2) { "http://example.com:8080#{path_2}" }
    let(:url_3) { "http://example.com:8080#{path_3}" }
    let(:response_1) { {"meta" => {}, "links" => {"first" => path_1, "last" => path_3, "next" => path_2, "prev" => nil}, "data" => [1, 2, 3]}.to_json }
    let(:response_2) { {"meta" => {}, "links" => {"first" => path_1, "last" => path_3, "next" => path_3, "prev" => path_1}, "data" => [4, 5, 6]}.to_json }
    let(:response_3) { {"meta" => {}, "links" => {"first" => path_1, "last" => path_3, "next" => nil, "prev" => path_2}, "data" => [7, 8]}.to_json }
    let(:non_paginated_response) { [1, 2, 3, 4, 5, 6, 7, 8].to_json }

    context "paginated responses" do
      it "with a block" do
        stub_rest_get(url_1, user_tenant_header, response_1)
        stub_rest_get(url_2, user_tenant_header, response_2)
        stub_rest_get(url_3, user_tenant_header, response_3)

        expect { |b| subject.send(:each_resource, url_1, user_tenant_account, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
      end

      it "enumerable" do
        stub_rest_get(url_1, user_tenant_header, response_1)
        stub_rest_get(url_2, user_tenant_header, response_2)
        stub_rest_get(url_3, user_tenant_header, response_3)

        expect(subject.send(:each_resource, url_1, user_tenant_account).collect(&:to_i)).to eq([1, 2, 3, 4, 5, 6, 7, 8])
      end
    end

    context "non-paginated responses" do
      it "with a block" do
        stub_rest_get(url_1, user_tenant_header, non_paginated_response)

        expect { |b| subject.send(:each_resource, url_1, user_tenant_account, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
      end

      it "enumerable" do
        stub_rest_get(url_1, user_tenant_header, non_paginated_response)

        expect(subject.send(:each_resource, url_1, user_tenant_account).collect(&:to_i)).to eq([1, 2, 3, 4, 5, 6, 7, 8])
      end
    end
  end

  describe "#create_openshift_objects_for_source" do
    let(:args)       { {"secret" => "secret", "source_id" => "1", "tenant" => user_tenant_account} }
    let(:connection) { double("Connection") }

    it "successful" do
      expect(subject.logger).to receive(:info).with("Creating objects for source 1 with digest digest")
      expect(subject.logger).to receive(:info).with("Secret topological-inventory-collector-source-1-secrets created for source 1")
      expect(subject.logger).to receive(:info).with("DeploymentConfig topological-inventory-collector-source-1 created for source 1")
      expect(subject.send(:object_manager)).to receive(:create_secret).with("topological-inventory-collector-source-1-secrets", "secret")
      expect(subject.send(:object_manager)).to receive(:check_deployment_config_quota)
      expect(subject.send(:object_manager)).to receive(:connection).and_return(connection)
      expect(connection).to receive(:create_deployment_config)

      expect(RestClient).to receive(:patch).with(
        "http://topology.local:8080/internal/v1.0/sources/1",
        "{\"refresh_status\":\"deployed\"}",
        user_tenant_header
      )

      subject.send(:create_openshift_objects_for_source, "digest", args)
    end

    it "failed quota check" do
      expect(subject.logger).to receive(:info).with("Creating objects for source 1 with digest digest")
      expect(subject.logger).to receive(:info).with("Secret topological-inventory-collector-source-1-secrets created for source 1")
      expect(subject.logger).to receive(:info).with("Skipping Deployment Config creation for source 1 because it would exceed quota.")
      expect(subject.send(:object_manager)).to receive(:create_secret).with("topological-inventory-collector-source-1-secrets", "secret")
      expect(subject.send(:object_manager)).to receive(:check_deployment_config_quota).and_raise(::TopologicalInventory::Orchestrator::ObjectManager::QuotaCpuLimitExceeded)
      allow(subject.send(:object_manager)).to receive(:connection).and_return(connection)
      expect(connection).not_to receive(:create_deployment_config)

      expect(RestClient).to receive(:patch).with(
        "http://topology.local:8080/internal/v1.0/sources/1",
        "{\"refresh_status\":\"quota_limited\"}",
        user_tenant_header
      )

      subject.send(:create_openshift_objects_for_source, "digest", args)
    end
  end

  def stub_rest_get(path, tenant_header, response)
    expect(RestClient).to receive(:get).with(path, tenant_header).and_return(response)
  end

  def stub_rest_get_404(path, tenant_header)
    expect(RestClient).to receive(:get).with(path, tenant_header).and_raise(RestClient::NotFound)
  end
end
