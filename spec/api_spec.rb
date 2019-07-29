describe TopologicalInventory::Orchestrator::Api do
  include MockData
  include Functions

  describe "#internal_url_for" do
    let(:api) { TopologicalInventory::Orchestrator::Api.new(:sources_api => sources_api, :topology_api => topology_api) }

    it "replaces the path with /internal/v0.1/<path>" do
      expect(api.send(:topology_internal_url_for, "the/best/path")).to eq("http://topology.local:8080/internal/v1.0/the/best/path")
    end
  end

  describe "#each_resource" do
    let(:api) { TopologicalInventory::Orchestrator::Api.new(:sources_api => sources_api, :topology_api => topology_api) }
    let(:path1) { "/api/topological-inventory/v1.0/some_collection" }
    let(:path2) { "/api/topological-inventory/v1.0/some_collection?offset=10&limit=10" }
    let(:path3) { "/api/topological-inventory/v1.0/some_collection?offset=20&limit=10" }
    let(:url1) { "http://example.com:8080#{path1}" }
    let(:url2) { "http://example.com:8080#{path2}" }
    let(:url3) { "http://example.com:8080#{path3}" }
    let(:response1) { { "meta" => {}, "links" => {"first" => path1, "last" => path3, "next" => path2, "prev" => nil}, "data" => [1, 2, 3] }.to_json }
    let(:response2) { { "meta" => {}, "links" => {"first" => path1, "last" => path3, "next" => path3, "prev" => path1}, "data" => [4, 5, 6] }.to_json }
    let(:response3) { { "meta" => {}, "links" => {"first" => path1, "last" => path3, "next" => nil, "prev" => path2}, "data" => [7, 8] }.to_json }
    let(:non_paginated_response) { [1, 2, 3, 4, 5, 6, 7, 8].to_json }

    context "paginated responses" do
      before do
        stub_rest_get(url1, user_tenant_header, response1)
        stub_rest_get(url2, user_tenant_header, response2)
        stub_rest_get(url3, user_tenant_header, response3)
      end

      it "with a block" do
        expect { |b| api.send(:each_resource, url1, user_tenant_account, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
      end

      it "enumerable" do
        expect(api.send(:each_resource, url1, user_tenant_account).collect(&:to_i)).to eq([1, 2, 3, 4, 5, 6, 7, 8])
      end
    end

    context "non-paginated responses" do
      it "with a block" do
        stub_rest_get(url1, user_tenant_header, non_paginated_response)
        expect { |b| api.send(:each_resource, url1, user_tenant_account, &b) }.to yield_successive_args(1, 2, 3, 4, 5, 6, 7, 8)
      end

      it "enumerable" do
        stub_rest_get(url1, user_tenant_header, non_paginated_response)
        expect(api.send(:each_resource, url1, user_tenant_account).collect(&:to_i)).to eq([1, 2, 3, 4, 5, 6, 7, 8])
      end
    end
  end
end
