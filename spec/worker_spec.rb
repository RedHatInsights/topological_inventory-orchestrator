describe TopologicalInventory::Orchestrator::Worker do
  context "#collectors_from_database" do
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

    it "generates the expected hash" do
      db = {}
      instance = described_class.new(api_base_url: "base_url")

      expect(RestClient).to receive(:get).with("base_url/source_types").and_return(source_types_response)
      expect(RestClient).to receive(:get).with("base_url/source_types/1/sources").and_return(source_types_1_sources_response)
      expect(RestClient).to receive(:get).with("base_url/sources/1/endpoints").and_return(sources_1_endpoints_response)
      expect(RestClient).to receive(:get).with("base_url/sources/2/endpoints").and_return(sources_2_endpoints_response)
      expect(instance).to receive(:authentication_for_endpoint).with(1).and_return({"username" => "USER", "password" => "PASS"})

      expect(RestClient).not_to receive(:get).with("base_url/source_types/2/sources")
      expect(instance).to_not receive(:authentication_for_endpoint).with(8)
      expect(instance).to_not receive(:authentication_for_endpoint).with(9)

      instance.send(:collectors_from_database, db)

      expect(db).to eq(
        {
          "998b3e45e7dcc535f549126eb8aa92e81344d9b3" => {
            "host"       => "example.com",
            "image"      => "docker-registry.default.svc:5000/topological-inventory-ci/topological-inventory-collector-openshift:latest",
            "source_id"  => "2",
            "source_uid" => "31b5338b-685d-4056-ba39-d00b4d7f19cc",
            "secret"     => {
              "password" => "PASS",
              "username" => "USER"
            },
          }
        }
      )
    end
  end

  it "#each_resource" do
    instance = described_class.new

    url_1 = "http://example.com/1"
    url_2 = "http://example.com/2"
    url_3 = "http://example.com/3"
    response_1 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => url_2, "prev" => nil}, "data" => [1, 2, 3]}.to_json
    response_2 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => url_3, "prev" => url_1}, "data" => [4, 5, 6]}.to_json
    response_3 = {"meta" => {}, "links" => {"first" => url_1, "last" => url_3, "next" => nil, "prev" => url_2}, "data" => [7, 8]}.to_json

    expect(RestClient).to receive(:get).with(url_1).and_return(response_1)
    expect(RestClient).to receive(:get).with(url_2).and_return(response_2)
    expect(RestClient).to receive(:get).with(url_3).and_return(response_3)

    expect { |b| instance.send(:each_resource, url_1, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
  end
end
