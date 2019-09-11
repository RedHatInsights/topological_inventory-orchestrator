require 'yaml'

describe TopologicalInventory::Orchestrator::ConfigMap do
  include MockData

  let(:object_manager) { double('object_manager') }
  let(:openshift_object) { double('openshift_object') }
  let(:source) { double('source') }
  let(:source2) { double('source2') }
  let(:source_type) { TopologicalInventory::Orchestrator::SourceType.new(source_types_data[:openshift]) }
  let(:secret) { double('secret') }
  let(:deployment_config) { double('deployment_config') }

  let(:config_map) { described_class.new(object_manager, openshift_object) }

  before do
    allow(source).to receive(:source_type).and_return(source_type)
    allow(source).to receive(:[]) { |arg| arg == 'uid' ? 'source-1' : nil }
    allow(source2).to receive(:source_type).and_return(source_type)
    allow(source2).to receive(:[]) { |arg| arg == 'uid' ? 'source-2' : nil }

    allow(config_map).to receive_messages(
      :logger                => double('logger').as_null_object,
      :new_secret            => secret,
      :new_deployment_config => deployment_config,
      :source_type           => source_type,
      :uid                   => '1'
    )

    config_map_def = { :metadata => { :labels => {} }, :data => {} }
    allow(object_manager).to receive(:create_config_map).and_yield(config_map_def)

    allow(secret).to receive(:config_map=)
    allow(deployment_config).to receive(:config_map=)
  end

  describe "#init_from_source" do
    before do
      allow(secret).to receive(:create_in_openshift)
      allow(deployment_config).to receive(:create_in_openshift)

      allow(config_map).to receive(:yaml_from_sources).and_return("")
    end

    it "creates secret and deployment_config" do
      expect(secret).to receive(:create_in_openshift)
      expect(deployment_config).to receive(:create_in_openshift)

      allow(source).to receive(:digest).and_return('1234')

      config_map.init_from_source!(source)

      expect(config_map.secret).to eq(secret)
      expect(config_map.deployment_config).to eq(deployment_config)
    end
  end

  context "add or remove" do
    let(:config_map_data) { OpenStruct.new }
    let(:endpoint1) { {'scheme' => 'https', 'host' => 'one.example.com', 'port' => 443, 'path' => nil} }
    let(:endpoint2) { {'scheme' => 'https', 'host' => 'two.example.com', 'port' => 443, 'path' => '/api'} }
    before do
      allow(openshift_object).to receive(:data).and_return(config_map_data)
    end

    describe "#add_source" do
      it "updates map's data and secret" do
        digest, digest2 = "12345", "23456"
        allow(config_map).to receive_messages(:available? => true,
                                              :digests    => [])
        allow(source).to receive_messages(:digest           => digest,
                                          :endpoint         => endpoint1,
                                          :from_sources_api => true)

        allow(source2).to receive_messages(:digest           => digest2,
                                           :endpoint         => endpoint2,
                                           :from_sources_api => true)

        allow(object_manager).to receive(:update_config_map)

        expect(object_manager).to receive(:update_config_map).twice

        # Add both sources to config map
        [source, source2].each do |s|
          config_map.add_source(s)
        end

        expect(config_map.send(:digests)).to eq([digest, digest2])
        expect(config_map.sources).to eq([source, source2])

        # Get data from openshift object
        # Compare it with endpoints and source uids
        loaded_data = YAML.load(config_map_data['custom.yml'])
        expected_data = [
          endpoint1.transform_keys!(&:to_sym).merge(:source => source['uid']),
          endpoint2.transform_keys!(&:to_sym).merge(:source => source2['uid'])
        ]
        expect(loaded_data[:sources]).to eq(expected_data)
      end

      it "adds only source with digest" do
        allow(config_map).to receive_messages(:available? => true,
                                              :digests    => [],
                                              :update!    => nil)

        # Source without digest isn't added
        allow(source).to receive(:digest).and_return([])
        config_map.add_source(source)
        expect(config_map.sources).to eq([])

        # Source with digest is added
        allow(source).to receive(:digest).and_return("qwerty")
        config_map.add_source(source)
        expect(config_map.sources.first).to eq(source)
      end

      it "cannot add the same source twice" do
        allow(config_map).to receive_messages(:available? => true,
                                              :digests    => [],
                                              :update!    => nil)

        allow(source).to receive(:digest).and_return("qwerty")

        config_map.add_source(source)
        expect(config_map.sources.size).to eq(1)
        # 2nd add doesn't have an effect
        config_map.add_source(source)
        expect(config_map.sources.size).to eq(1)
      end

      it "cannot add source of different type" do
        allow(source).to receive_messages(:digest => nil)
        allow(source_type).to receive_messages(:sources_per_collector => 1)

        allow(source).to receive(:source_type).and_return({})
        expect { config_map.add_source(source) }.to raise_exception("ConfigMap not available")
      end

      it "cannot add source to full config-map" do
        allow(source).to receive_messages(:digest      => nil,
                                          :source_type => source_type)
        # Max one source
        allow(source_type).to receive_messages(:sources_per_collector => 1)

        expect { config_map.add_source(source) }.not_to raise_exception
        config_map.sources << double

        expect { config_map.add_source(source) }.to raise_exception("ConfigMap not available")
      end
    end

    describe "#remove_source" do
      it "updates map's data and secret" do
        digest, digest2 = "digest1", "digest2"
        allow(config_map).to receive_messages(:available?        => true,
                                              :digests           => [],
                                              :deployment_config => deployment_config,
                                              :secret            => secret)
        allow(source).to receive_messages(:digest           => digest,
                                          :endpoint         => endpoint1,
                                          :from_sources_api => true)

        allow(source2).to receive_messages(:digest           => digest2,
                                           :endpoint         => endpoint2,
                                           :from_sources_api => true)

        allow(object_manager).to receive(:update_config_map)
        allow(object_manager).to receive(:delete_config_map)

        allow(secret).to receive(:delete_in_openshift)
        allow(secret).to receive(:update!)
        allow(deployment_config).to receive(:delete_in_openshift)

        # 2x add, 1x remove, last remove doesn't update, but delete
        expect(object_manager).to receive(:update_config_map).exactly(3).times
        expect(secret).to receive(:update!).exactly(3).times

        # Add both sources to config map
        config_map.add_source(source)
        config_map.add_source(source2)

        expect(config_map.send(:digests)).to eq([digest, digest2])
        expect(config_map.sources).to eq([source, source2])

        # Remove first source
        config_map.remove_source(source)

        # Get data from openshift object
        # Compare it with endpoints and source uids
        loaded_data = YAML.load(config_map_data['custom.yml'])
        expected_data = [
          endpoint2.transform_keys!(&:to_sym).merge(:source => source2['uid'])
        ]
        expect(loaded_data[:sources]).to eq(expected_data)
        expect(config_map.sources).to eq([source2])

        # Remove 2nd source
        expect(object_manager).to receive(:delete_config_map).once
        expect(deployment_config).to receive(:delete_in_openshift)
        expect(secret).to receive(:delete_in_openshift)
        config_map.remove_source(source2)
      end
    end
  end

  describe "#associate_sources" do
    let(:digests) { (1..5).collect { |i| "digest-#{i}" } }

    it "finds in digests or creates new" do
      allow(config_map).to receive(:digests).and_return(digests)

      sources_by_digest = {}
      [2, 4].each do |idx|
        TopologicalInventory::Orchestrator::Source.new({}, nil, nil, '', :from_sources_api => true).tap do |source|
          source.digest = digests[idx]
          sources_by_digest[source.digest] = source
        end
      end

      config_map.associate_sources(sources_by_digest)

      expect(config_map.sources.size).to eq(digests.size)

      sources_new = 0
      config_map.sources.each do |source|
        expect(source.config_map).to eq(config_map)
        expect(source.digest).not_to eq(nil)
        sources_new += 1 unless source.from_sources_api
      end

      # 5 digests, 2 input sources => 5 - 2 == 3
      expect(sources_new).to eq(3)

      # input parameter is used later and contains all sources
      expect(sources_by_digest.keys.sort).to eq(digests.sort)
    end
  end
end
