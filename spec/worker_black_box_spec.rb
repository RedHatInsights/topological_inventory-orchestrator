describe TopologicalInventory::Orchestrator::Worker do
  include Functions

  around do |e|
    ENV["IMAGE_NAMESPACE"] = "buildfactory"
    e.run
    ENV.delete("IMAGE_NAMESPACE")
  end

  let(:kube_client) { TopologicalInventory::Orchestrator::TestModels::KubeClient.new }
  let(:object_manager) { TopologicalInventory::Orchestrator::TestModels::ObjectManager.new(kube_client) }

  # Predefined responses
  let(:empty_list_response) { list([]) }
  let(:tenants_response) { list([tenants[user_tenant_account]]) }
  let(:application_types_response) { list(application_types_data) }
  let(:applications_response) { list(applications_data.values) }

  subject do
    allow(described_class).to receive(:path_to_config).and_return(File.expand_path("../config", File.dirname(__FILE__)))
    described_class.new(:collector_image_tag => "dev", :sources_api => sources_api, :topology_api => topology_api)
  end

  before do
    # Turn off logger
    allow(TopologicalInventory::Orchestrator).to receive(:logger).and_return(double('logger').as_null_object)

    # Get testing object_manager/kube_client
    allow(subject).to receive(:object_manager).and_return(object_manager)

    # Disable Quota test in this spec
    allow(subject.api).to receive(:update_topological_inventory_source_refresh_status).and_return(nil)

    # Count number of added and removed sources
    @added, @removed = 0, 0
    allow_any_instance_of(TopologicalInventory::Orchestrator::Source).to receive(:add_to_openshift).and_wrap_original do |m, *args|
      m.call(*args)
      @added += 1
    end
    allow_any_instance_of(TopologicalInventory::Orchestrator::Source).to receive(:remove_from_openshift).and_wrap_original do |m, *args|
      m.call(*args)
      @removed += 1
    end
  end

  context "loads no data in API, empty openshift" do
    before do
      # Init of api calls
      stub_api_init(:application_types => application_types_response,
                    :applications      => empty_list_response,
                    :source_types      => empty_list_response,
                    :tenants           => tenants_response,
                    :topology_sources  => empty_list_response)
    end

    it "doesn't create or remove collector" do
      # Run orchestrator
      subject.send(:make_openshift_match_database)

      # Check add/remove calls
      expect(@added).to eq(0)
      expect(@removed).to eq(0)

      # Check against "Openshift" (Mock KubeClient)
      assert_openshift_objects_count(0)
    end
  end

  context "loads data from API, empty openshift," do
    let(:source_types_response) { list(source_types_data.values) }

    before do
      # Init of api calls
      stub_api_init(:application_types => application_types_response,
                    :applications      => applications_response,
                    :source_types      => source_types_response,
                    :tenants           => tenants_response,
                    :topology_sources  => topology_sources_response) # defined in sub-contexts
    end

    context "with sources of the same source_type (openshift)," do
      let(:topology_sources_response) { list(topological_sources[:openshift].values) }
      let(:available_sources_size) { available_sources_data(:openshift).keys.size }

      (1..3).each do |sources_per_collector|
        it "#{sources_per_collector} sources per collector" do
          # Init config
          init_config(:openshift => sources_per_collector)

          # Init Source API calls
          sources_data[:openshift].each_value { |source| stub_api_source_calls(source) }

          # Run orchestrator
          subject.send(:make_openshift_match_database)

          # Check add/remove calls
          expect(@added).to eq(available_sources_size)
          expect(@removed).to eq(0)

          # Check against "Openshift" (Mock KubeClient)
          objects_cnt = available_sources_size / sources_per_collector
          objects_cnt += 1 if available_sources_size % sources_per_collector > 0

          assert_openshift_objects_count(objects_cnt)

          available_sources_data(:openshift).each_value { |source| assert_openshift_objects_data(source) }
        end
      end
    end

    context "with sources of different types," do
      let(:topology_sources_response) { list(topological_sources[:openshift].values + topological_sources[:amazon].values) }
      let(:available_sources_size) { available_sources_data(:openshift).keys.size + available_sources_data(:amazon).keys.size }

      (1..3).each do |sources_per_collector|
        it "#{sources_per_collector} sources per config_map" do
          # Init config
          init_config(:openshift => sources_per_collector,
                      :amazon    => sources_per_collector)

          # Init Source API calls
          sources_data[:openshift].each_value { |source| stub_api_source_calls(source) }
          sources_data[:amazon].each_value { |source| stub_api_source_calls(source) }

          # Run orchestrator
          subject.send(:make_openshift_match_database)

          # Check add/remove calls
          expect(@added).to eq(available_sources_size)
          expect(@removed).to eq(0)

          # Check against "Openshift" (Mock KubeClient)
          objects_cnt = 0
          %i[openshift amazon].each do |source_type_name|
            objects_cnt += available_sources_data(source_type_name).keys.size / sources_per_collector
            objects_cnt += 1 if available_sources_data(source_type_name).keys.size % sources_per_collector > 0
          end
          assert_openshift_objects_count(objects_cnt)

          available_sources_data(:openshift).each_value { |source| assert_openshift_objects_data(source) }
          available_sources_data(:amazon).each_value { |source| assert_openshift_objects_data(source) }
        end
      end
    end

    context "with sources of unsupported type" do
      let(:topology_sources_response) { list(topological_sources[:mock].values) }
      let(:sources_size) { sources_data[:mock].keys.size }

      it "doesn't create any object" do
        # only source/<id> is called, then it doesn't fit to collected source types
        sources_data[:mock].each_value { |s| stub_api_source_get(s, show(s)) }

        subject.send(:make_openshift_match_database)
        expect(@added).to eq(0)
      end
    end
  end

  context "loads data from both API and OpenShift," do
    let(:source_types_response) { list(source_types_data.values) }

    context "without API data" do
      before do
        # Fill openshift first
        #
        # 1st sync
        #
        @sources_in_openshift = topological_sources[:openshift].values + topological_sources[:amazon].values
        @available_sources = available_sources_data(:openshift).values + available_sources_data(:amazon).values

        stub_api_init(:application_types => application_types_response,
                      :applications      => applications_response,
                      :source_types      => source_types_response,
                      :tenants           => tenants_response,
                      :topology_sources  => list(@sources_in_openshift))

        init_config(:openshift => 1, :amazon => 2) # per collector

        sources_data[:openshift].each_value { |s| stub_api_source_calls(s) }
        sources_data[:amazon].each_value { |s| stub_api_source_calls(s) }

        subject.send(:make_openshift_match_database)

        expect(@added).to eq(@available_sources.size)

        assert_openshift_objects_count(2 + 1) # 2 for openshift, 1 for amazon
        @added = 0 # reset
      end

      it "removes OpenShift objects" do
        #
        # 2nd sync
        #
        # :application_types request cached
        stub_api_init(:applications      => applications_response,
                      :source_types      => source_types_response,
                      :tenants           => tenants_response,
                      :topology_sources  => empty_list_response)

        subject.send(:make_openshift_match_database)

        expect(@added).to eq(0)
        expect(@removed).to eq(@available_sources.size)

        assert_openshift_objects_count(0)
      end
    end

    context "with nonempty API data" do
      before do
        stub_const("TopologicalInventory::Orchestrator::SourceType::SUPPORTED_TYPES", %w[openshift amazon azure])
        # Fill openshift first
        #
        # 1st sync
        #
        @sources_in_openshift = [topological_sources[:openshift]['1'],
                                 topological_sources[:openshift]['2'],
                                 topological_sources[:amazon]['4'],
                                 topological_sources[:amazon]['5']]
        @available_sources = [available_sources_data(:openshift)['1'],
                              available_sources_data(:openshift)['2'],
                              available_sources_data(:amazon)['4'],
                              available_sources_data(:amazon)['5']].compact

        stub_api_init(:application_types => application_types_response,
                      :applications      => applications_response,
                      :source_types      => source_types_response,
                      :tenants           => tenants_response,
                      :topology_sources  => list(@sources_in_openshift))

        init_config(:openshift => 1, :amazon => 1, :azure => 1) # per collector

        stub_api_source_calls(sources_data[:openshift]['1'])
        stub_api_source_calls(sources_data[:openshift]['2'])
        stub_api_source_calls(sources_data[:amazon]['4'])
        stub_api_source_calls(sources_data[:amazon]['5'])

        # Run orchestrator
        subject.send(:make_openshift_match_database)
        expect(@added).to eq(@available_sources.size)

        assert_openshift_objects_count(1 + 2) # 1 for openshift, 2 for amazon

        @added = 0 # reset
      end

      it "adds new, keeps existing, removes missing sources" do
        #
        # 2nd sync
        #
        # added 1 azure + 1 amazon, deleted 1 openshift + 1 amazon
        sources_from_api = [topological_sources[:openshift]['1'],
                            topological_sources[:amazon]['4'],
                            topological_sources[:amazon]['6'], # new
                            topological_sources[:azure]['7']]  # new

        # :application_types request cached
        stub_api_init(:applications      => applications_response,
                      :source_types      => source_types_response,
                      :tenants           => tenants_response,
                      :topology_sources  => list(sources_from_api))

        stub_api_source_calls(sources_data[:openshift]['1'])
        stub_api_source_calls(sources_data[:amazon]['4'])
        stub_api_source_calls(sources_data[:amazon]['6'])
        stub_api_source_calls(sources_data[:azure]['7'])

        # Run orchestrator
        subject.send(:make_openshift_match_database)

        expect(@added).to eq(1)     # azure/7
        expect(@removed).to eq(1)   # openshift/2

        assert_openshift_objects_count(1 + 1 + 1) # openshift + azure + amazon
        assert_openshift_objects_data(sources_data[:openshift]['1'])
        assert_openshift_objects_data(sources_data[:openshift]['2'], :missing => true)
        assert_openshift_objects_data(sources_data[:amazon]['4'])
        assert_openshift_objects_data(sources_data[:amazon]['5'], :missing => true)
        assert_openshift_objects_data(sources_data[:amazon]['6'], :missing => true)
        assert_openshift_objects_data(sources_data[:azure]['7']) # added
      end
    end
  end
end
