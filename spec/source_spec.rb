describe TopologicalInventory::Orchestrator::Source do
  include MockData

  let(:collector_definition) { { "image" => "topological-inventory-openshift:latest" } }

  before do
    @source = described_class.new(sources_data[:openshift]["1"], nil,
                                  double, collector_definition,
                                  :from_sources_api => true)
  end

  context "#add_to_openshift" do
    let(:config_maps) { [double, double, double] }

    it "with free config_map" do
      allow(config_maps[0]).to receive(:available?).and_return(false)
      allow(config_maps[1]).to receive(:available?).and_return(true)
      allow(config_maps[2]).to receive(:available?).and_return(false)
      config_maps.each { |map| allow(map).to receive(:add_source) }

      expect(config_maps[1]).to receive(:add_source).once

      @source.add_to_openshift(double, config_maps)
      expect(@source.config_map).to eq(config_maps[1])
    end

    it "with no or no free config map" do
      allow(@source).to receive(:deploy_new_collector)
      expect(@source).to receive(:deploy_new_collector)

      @source.add_to_openshift(double, [])

      config_maps.each { |map| allow(map).to receive(:available?).and_return(false) }

      allow(@source).to receive(:deploy_new_collector)
      expect(@source).to receive(:deploy_new_collector)

      @source.add_to_openshift(double, config_maps)
    end
  end

  context "#remove_from_openshift" do
    it "removes it from config map" do
      config_map = double("config_map")
      @source.config_map = config_map

      expect(config_map).to receive(:remove_source)

      @source.remove_from_openshift
    end
  end

  context "#load_credentials" do
    it "calls api 3 times" do
      endpoint, authentication, credentials = double, double, double
      allow(endpoint).to receive(:[])
      allow(authentication).to receive(:[])

      api = double("api")
      allow(api).to receive_messages(:get_endpoint       => endpoint,
                                     :get_authentication => authentication,
                                     :get_credentials    => credentials)

      @source.load_credentials(api)

      expect(@source.endpoint).to eq(endpoint)
      expect(@source.authentication).to eq(authentication)
      expect(@source.credentials).to eq(credentials)
    end
  end
end
