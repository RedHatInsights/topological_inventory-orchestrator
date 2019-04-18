describe TopologicalInventory::Orchestrator::Worker do
  let(:tenants_response) do
    <<~EOJ
      [
        {
          "id": "1",
          "external_tenant": "#{user_tenant_account}"
        }
      ]
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

  subject { described_class.new(sources_api: sources_api, topology_api: topology_api) }

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

    let(:topology_sources_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","uid":"cacebc33-1ed8-49d4-b4f9-713f2552ee65","tenant_id":"1"},
            {"id":"2","uid":"31b5338b-685d-4056-ba39-d00b4d7f19cc","tenant_id":"1"}
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
      stub_rest_get("http://topology.local:8080/internal/v0.0/tenants", orchestrator_tenant_header, tenants_response)
      stub_rest_get("#{topology_api}/sources", user_tenant_header, topology_sources_response)
      stub_rest_get("#{sources_api}/sources/1", user_tenant_header, sources_1_response)
      stub_rest_get("#{sources_api}/sources/1/endpoints", user_tenant_header, sources_1_endpoints_response)
      stub_rest_get("#{sources_api}/sources/2", user_tenant_header, sources_2_response)
      stub_rest_get("#{sources_api}/sources/2/endpoints", user_tenant_header, sources_2_endpoints_response)
      stub_rest_get("#{sources_api}/endpoints/1/authentications", user_tenant_header, endpoints_1_authentications_response)
      stub_rest_get("http://sources.local:8080/internal/v1.0/authentications/1?expose_encrypted_attribute[]=password", user_tenant_header, {"username" => "USER", "password" => "PASS"}.to_json)

      expect(RestClient).not_to receive(:get).with("#{sources_api}/endpoints/8/authentications", any_args)
      expect(RestClient).not_to receive(:get).with("#{sources_api}/endpoints/9/authentications", any_args)
      expect(RestClient).not_to receive(:get).with("http://sources.local:8080/internal/v1.0/authentications/8?expose_encrypted_attribute[]=password", any_args)
      expect(RestClient).not_to receive(:get).with("http://sources.local:8080/internal/v1.0/authentications/9?expose_encrypted_attribute[]=password", any_args)

      collector_hash = subject.send(:collectors_from_sources_api)

      expect(collector_hash).to eq(
        "09ff859d6a98e23d69968d1419bf8b25b910d3ee" => {
          "endpoint_host"   => "example.com",
          "endpoint_path"   => "/api",
          "endpoint_port"   => "8443",
          "endpoint_scheme" => "https",
          "image"           => "topological-inventory-openshift:latest",
          "image_namespace" => "buildfactory",
          "source_id"       => "2",
          "source_uid"      => "31b5338b-685d-4056-ba39-d00b4d7f19cc",
          "secret"          => {
            "password" => "PASS",
            "username" => "USER"
          },
        }
      )
    end
  end

  describe "#internal_url_for" do
    it "replaces the path with /internal/v0.1/<path>" do
      expect(subject.send(:topology_internal_url_for, "the/best/path")).to eq("http://topology.local:8080/internal/v0.0/the/best/path")
    end
  end

  describe "#each_resource" do
    it "works with paginated responses" do
      url_1 = "http://example.com:8080/1"
      url_2 = "http://example.com:8080/2"
      url_3 = "http://example.com:8080/3"
      response_1 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => url_2, "prev" => nil}, "data" => [1, 2, 3]}.to_json
      response_2 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => url_3, "prev" => url_1}, "data" => [4, 5, 6]}.to_json
      response_3 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => nil, "prev" => url_2}, "data" => [7, 8]}.to_json

      stub_rest_get(url_1, user_tenant_header, response_1)
      stub_rest_get(url_2, user_tenant_header, response_2)
      stub_rest_get(url_3, user_tenant_header, response_3)

      expect { |b| subject.send(:each_resource, url_1, user_tenant_account, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
    end

    it "works with non-paginated responses" do
      url = "http://example.com:8080/things"
      response = [1, 2, 3, 4, 5, 6, 7, 8].to_json

      stub_rest_get(url, user_tenant_header, response)
      expect { |b| subject.send(:each_resource, url, user_tenant_account, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
    end
  end

  def stub_rest_get(path, tenant_header, response)
    expect(RestClient).to receive(:get).with(path, tenant_header).and_return(response)
  end
end
