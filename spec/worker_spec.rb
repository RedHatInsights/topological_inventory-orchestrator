describe TopologicalInventory::Orchestrator::Worker do
  around do |e|
    ENV["TOPOLOGICAL_INVENTORY_API_SERVICE_HOST"] = "example.com"
    ENV["TOPOLOGICAL_INVENTORY_API_SERVICE_PORT"] = "8080"
    ENV["IMAGE_NAMESPACE"] = "buildfactory"

    e.run

    ENV.delete("TOPOLOGICAL_INVENTORY_API_SERVICE_HOST")
    ENV.delete("TOPOLOGICAL_INVENTORY_API_SERVICE_PORT")
    ENV.delete("IMAGE_NAMESPACE")
  end

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

    let(:source_types_1_sources_response) do
      <<~EOJ
        {
          "links": {},
          "data": [
            {"id":"1","source_type_id":"1","name":"mock-source","uid":"cacebc33-1ed8-49d4-b4f9-713f2552ee65","tenant_id":"1"},
            {"id":"2","source_type_id":"1","name":"OCP","uid":"31b5338b-685d-4056-ba39-d00b4d7f19cc","tenant_id":"1"}
          ]
        }
      EOJ
    end

    let(:source_types_2_sources_response) do
      <<~EOJ
        {
          "links": {},
          "data": []
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
      db = {}
      instance = described_class.new

      expect(RestClient).to receive(:get).with("http://example.com:8080/v0.1/source_types").and_return(source_types_response)
      expect(RestClient).to receive(:get).with("http://example.com:8080/v0.1/source_types/1/sources").and_return(source_types_1_sources_response)
      expect(RestClient).to receive(:get).with("http://example.com:8080/v0.1/source_types/2/sources").and_return(source_types_2_sources_response)
      expect(RestClient).to receive(:get).with("http://example.com:8080/v0.1/sources/1/endpoints").and_return(sources_1_endpoints_response)
      expect(RestClient).to receive(:get).with("http://example.com:8080/v0.1/sources/2/endpoints").and_return(sources_2_endpoints_response)
      expect(RestClient).to receive(:get).with("http://example.com:8080/v0.1/authentications?resource_type=Endpoint&resource_id=1").and_return(endpoints_1_authentications_response)
      expect(RestClient).to receive(:get).with("http://example.com:8080/internal/v0.0/authentications/1?expose_encrypted_attribute[]=password").and_return({"username" => "USER", "password" => "PASS"}.to_json)

      expect(RestClient).not_to receive(:get).with("http://example.com:8080/v0.1/authentications?resource_type=Endpoint&resource_id=8")
      expect(RestClient).not_to receive(:get).with("http://example.com:8080/v0.1/authentications?resource_type=Endpoint&resource_id=9")
      expect(RestClient).not_to receive(:get).with("http://example.com:8080/internal/v0.0/authentications/8?expose_encrypted_attribute[]=password")
      expect(RestClient).not_to receive(:get).with("http://example.com:8080/internal/v0.0/authentications/9?expose_encrypted_attribute[]=password")

      instance.send(:collectors_from_sources_api, db)

      expect(db).to eq(
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

  it "#each_resource" do
    instance = described_class.new

    url_1 = "http://example.com:8080/1"
    url_2 = "http://example.com:8080/2"
    url_3 = "http://example.com:8080/3"
    response_1 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => url_2, "prev" => nil}, "data" => [1, 2, 3]}.to_json
    response_2 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => url_3, "prev" => url_1}, "data" => [4, 5, 6]}.to_json
    response_3 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => nil, "prev" => url_2}, "data" => [7, 8]}.to_json

    expect(RestClient).to receive(:get).with(url_1).and_return(response_1)
    expect(RestClient).to receive(:get).with(url_2).and_return(response_2)
    expect(RestClient).to receive(:get).with(url_3).and_return(response_3)

    expect { |b| instance.send(:each_resource, url_1, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
  end

  describe "#api_base_url (private)" do
    let(:url) { subject.send(:api_base_url) }

    it "returns a sane value" do
      expect(url).to eq("http://example.com:8080/v0.1")
    end

    context "with APP_NAME set" do
      around do |e|
        ENV["APP_NAME"] = "topological-inventory"
        e.run
        ENV.delete("APP_NAME")
        ENV.delete("PATH_PREFIX")
      end

      it "includes the APP_NAME" do
        expect(url).to eq("http://example.com:8080/topological-inventory/v0.1")
      end

      it "uses the PATH_PREFIX with a leading slash" do
        ENV["PATH_PREFIX"] = "/this/is/a/path"
        expect(url).to eq("http://example.com:8080/this/is/a/path/topological-inventory/v0.1")
      end

      it "uses the PATH_PREFIX without a leading slash" do
        ENV["PATH_PREFIX"] = "also/a/path"
        expect(url).to eq("http://example.com:8080/also/a/path/topological-inventory/v0.1")
      end
    end
  end
end
