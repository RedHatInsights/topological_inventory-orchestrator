# All mock data are based on predefined ids:
# - all relations are 1:1
# - it means that Source.id == 1 has Endpoint.id == 1 and Authentication.id == 1 etc.
describe TopologicalInventory::Orchestrator::TargetedUpdate do
  include Functions

  # Predefined responses
  let(:empty_list_response) { list([]) }
  let(:application_types_response) { list(application_types_data) }
  let(:sources_by_ids) { sources_data.values.reduce({}, :merge) } # Merge array of hashes)

  around do |e|
    ENV["IMAGE_NAMESPACE"] = "buildfactory"
    e.run
    ENV.delete("IMAGE_NAMESPACE")
  end

  let(:kube_client) { TopologicalInventory::Orchestrator::TestModels::KubeClient.new }
  let(:object_manager) { TopologicalInventory::Orchestrator::TestModels::ObjectManager.new(kube_client) }
  let(:worker) { TopologicalInventory::Orchestrator::Worker.new(:collector_image_tag => "dev", :sources_api => sources_api, :topology_api => topology_api) }

  subject do
    allow(described_class).to receive(:path_to_config).and_return(File.expand_path("../config", File.dirname(__FILE__)))
    described_class.new(worker)
  end

  before do
    # Clear cache
    TopologicalInventory::Orchestrator::Api.class_variable_set :@@cache_start, nil

    # Turn off logger
    allow(TopologicalInventory::Orchestrator).to receive(:logger).and_return(double('logger').as_null_object)

    # Get testing object_manager/kube_client
    allow(subject).to receive(:object_manager).and_return(object_manager)

    # Disable Quota test in this spec
    allow(subject.api).to receive(:update_topological_inventory_source_refresh_status).and_return(nil)
  end

  # @param source_types [Array<Symbol>] - source type names which are loaded by API calls
  # @param belongs_to [Hash<Symbol, Array<id>>] - list of belongs_to associations loaded by API calls (i.e. Source is loaded for Endpoint target)
  # @param has_one [Hash<Symbol, Array<id>>] - list of has_many associations loaded by API calls (i.e. Endpoints for Source) - in practice there is has_one always instead
  # @param request_app_types [Boolean] - Application_types request is cached so it's called only once
  def stub_api_targeted_init(source_types: [],
                             belongs_to: {},
                             has_one: {},
                             request_app_types: true,
                             tenant_header: user_tenant_header)
    stub_api_application_types_get(:response => application_types_response) if request_app_types

    stub_api_source_types_get(:request_params => request_filter(:id, source_types.collect { |name| source_types_data[name]['id'] }),
                              :response       => list(source_types.collect { |name| source_types_data[name] }))

    belongs_to.each_pair do |model, ids|
      case model
      when :endpoint
        stub_api_endpoints_get(:request_params => request_filter(:id, ids),
                               :response       => list(ids.collect { |id| endpoints[id] }),
                               :tenant_header  => tenant_header)
      when :source
        stub_api_sources_get(:request_params => request_filter(:id, ids),
                             :response       => list(ids.collect { |id| sources_by_ids[id] }),
                             :tenant_header  => tenant_header)
      end
    end

    has_one.each_pair do |model, ids|
      case model
      when :application
        stub_api_applications_get(:request_params => "#{request_filter(:source_id, ids)}&#{default_applications_filter}",
                                  :response       => list(ids.collect { |id| applications_data[id] }),
                                  :tenant_header  => tenant_header)
      when :endpoint
        stub_api_endpoints_get(:request_params => request_filter(:source_id, ids),
                               :response       => list(ids.collect { |id| endpoints[id] }),
                               :tenant_header  => tenant_header)
      when :authentication
        stub_api_authentications_get(:request_params => "filter[resource_type]=Endpoint&#{request_filter(:resource_id, ids)}",
                                     :response       => list(ids.collect { |id| authentications[id] }),
                                     :tenant_header  => tenant_header)
      when :credentials
        ids.each do |id|
          stub_api_credentials_get(id, :response => show(credentials[id]), :tenant_header => tenant_header)
        end
      end
    end
  end

  context "#create targets" do
    it "creates a source from Source.create event" do
      id = '1'
      subject.add_target('Source', 'create', sources_data[:openshift][id])

      stub_api_targeted_init(:source_types => %i[openshift],
                             :has_one      => {:application => [id], :endpoint => [id], :authentication => [id], :credentials => [id]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(1)
    end

    it "creates a source from Authentication.create event" do
      id = '3'
      subject.add_target('Authentication', 'create', authentications[id])

      stub_api_targeted_init(:source_types => %i[openshift],
                             :belongs_to   => {:endpoint => [id], :source => [id]},
                             :has_one      => {:application => [id], :credentials => [id]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(1)
    end

    it "creates a source from Endpoint.create event" do
      id = '1'
      subject.add_target('Endpoint', 'create', endpoints[id])

      stub_api_targeted_init(:source_types => %i[openshift],
                             :belongs_to   => {:source => [id]},
                             :has_one      => {:application => [id], :authentication => [id], :credentials => [id]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(1)
    end

    it "creates a source from Application.create event" do
      id = '1'
      subject.add_target('Application', 'create', applications_data[id])

      stub_api_targeted_init(:source_types => %i[openshift],
                             :belongs_to   => {:source => [id]},
                             :has_one      => {:endpoint => [id], :authentication => [id], :credentials => [id]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(1)
    end

    # it simulates UI
    it "creates a source from <all>.create events" do
      id = '1'
      subject.add_target('Source', 'create', sources_data[:openshift][id])
      subject.add_target('Endpoint', 'create', endpoints[id])
      subject.add_target('Authentication', 'create', authentications[id])
      subject.add_target('Application', 'create', applications_data[id])

      stub_api_targeted_init(:source_types => %i[openshift],
                             :belongs_to   => {:endpoint => [id], :source => [id]},
                             :has_one      => {:application => [id], :endpoint => [id], :authentication => [id], :credentials => [id]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(1)
      assert_openshift_objects_data(sources_data[:openshift][id])
    end

    it "creates 2 sources from 3 events" do
      @id1, @id2 = '1', '4' # openshift + amazon
      subject.add_target('Source', 'create', sources_data[:openshift][@id1])
      subject.add_target('Authentication', 'create', authentications[@id2])
      subject.add_target('Application', 'create', applications_data[@id2])

      stub_api_targeted_init(:source_types => %i[openshift amazon],
                             :belongs_to   => {:endpoint => [@id2], :source => [@id2]},
                             :has_one      => {:application => [@id1, @id2], :endpoint => [@id1, @id2], :authentication => [@id1, @id2], :credentials => [@id1, @id2]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(2)
      assert_openshift_objects_data(sources_data[:openshift][@id1])
      assert_openshift_objects_data(sources_data[:amazon][@id2])
    end
  end

  context "#update/#delete targets" do
    before do
      init_config(:openshift => 2, :amazon => 1) # per collector

      @id1, @id2, @id3, @id4 = '1', '3', '4', '5' # only available sources
      subject.add_target('Source', 'create', sources_data[:openshift][@id1])
      subject.add_target('Source', 'create', sources_data[:openshift][@id2])
      subject.add_target('Source', 'create', sources_data[:amazon][@id3])
      subject.add_target('Source', 'create', sources_data[:amazon][@id4])

      stub_api_targeted_init(:source_types => %i[openshift amazon],
                             :belongs_to   => {},
                             :has_one      => {:application    => [@id1, @id2, @id3, @id4],
                                               :endpoint       => [@id1, @id2, @id3, @id4],
                                               :authentication => [@id1, @id2, @id3, @id4],
                                               :credentials    => [@id1, @id2, @id3, @id4]})

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(3) # 1 openshift + 2 amazon
      assert_openshift_objects_data(sources_data[:openshift][@id1])
      assert_openshift_objects_data(sources_data[:openshift][@id2])
      assert_openshift_objects_data(sources_data[:amazon][@id3])
      assert_openshift_objects_data(sources_data[:amazon][@id4])

      subject.clear_targets
    end

    it "updates sources and keeps others unchanged" do
      changed_source = sources_data[:openshift][@id1].merge('name' => 'Changed!')
      changed_endpoint = endpoints[@id3].merge('host' => 'my-testing-url.com', 'receptor_node' => 'a-node')
      changed_digest = '54b460e847025e028bd9ebe6061ae94360853d08'

      subject.add_target('Source', 'update', changed_source)
      subject.add_target('Endpoint', 'update', changed_endpoint)

      stub_api_targeted_init(:source_types      => %i[openshift amazon],
                             :belongs_to        => {:source => [@id3]},
                             :has_one           => {:application => [@id1, @id3], :endpoint => [@id1], :authentication => [@id1, @id3], :credentials => [@id1, @id3]},
                             :request_app_types => false)
      subject.sync_targets_with_openshift

      assert_openshift_objects_count(3) # no change
      assert_openshift_objects_data(changed_source)
      assert_openshift_objects_data(sources_data[:openshift][@id2]) # no change
      assert_openshift_objects_data(sources_data[:amazon][@id3], :endpoint_data => changed_endpoint, :digest => changed_digest)
      assert_openshift_objects_data(sources_data[:amazon][@id4]) # no change
    end

    it "deletes sources and removes empty config maps/secrets/DCs" do
      subject.add_target('Source', 'destroy', sources_data[:openshift][@id1])
      subject.add_target('Source', 'destroy', sources_data[:amazon][@id4])

      # Endpoint and Auth/Credentials API calls are not needed for 'Source.destroy' event
      stub_api_targeted_init(:source_types      => %i[openshift amazon],
                             :belongs_to        => {},
                             :has_one           => {:application => [@id1, @id4]},
                             :request_app_types => false)

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(2) # 1 openshift + 1 amazon
      assert_openshift_objects_data(sources_data[:openshift][@id1], :missing => true)
      assert_openshift_objects_data(sources_data[:openshift][@id2])
      assert_openshift_objects_data(sources_data[:amazon][@id3])
      assert_openshift_objects_data(sources_data[:amazon][@id4], :missing => true)
    end

    it "handles multiple events of the same source" do
      changed_source = sources_data[:openshift][@id1].dup.merge('name' => 'Changed!')
      # update after destroy
      subject.add_target('Source', 'destroy', sources_data[:openshift][@id1])
      subject.add_target('Source', 'update', changed_source)
      # destroy destroyed
      subject.add_target('Source', 'destroy', sources_data[:openshift][@id2])
      subject.add_target('Source', 'destroy', sources_data[:openshift][@id2])
      # create existing
      subject.add_target('Endpoint', 'create', endpoints[@id3])
      # double update
      changed_source2a = sources_data[:amazon][@id4].dup.merge('name' => 'Amazon - change 1')
      subject.add_target('Source', 'update', changed_source2a)
      changed_source2b = sources_data[:amazon][@id4].dup.merge('name' => 'Amazon - change 2')
      subject.add_target('Source', 'update', changed_source2b)
      # update non-existing
      id5 = '6'
      new_source = sources_data[:amazon][id5].merge('availability_status' => 'available')
      subject.add_target('Source', 'update', new_source)

      # Auth/Credentials are not loaded for Source 2, because it has only 'destroy' events
      stub_api_targeted_init(:source_types      => %i[openshift amazon],
                             :belongs_to        => {:source => [@id3]},
                             :has_one           => {:application    => [@id1, @id2, @id3, @id4, id5],
                                                    :endpoint       => [@id1, @id4, id5],
                                                    :authentication => [@id1, @id3, @id4, id5],
                                                    :credentials    => [@id1, @id3, @id4, id5]},
                             :request_app_types => false)

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(4) # 1 openshift + 3 amazons
      # Update of destroyed should create new one
      assert_openshift_objects_data(changed_source)
      # Multiple destroy should be the same like single destroy
      assert_openshift_objects_data(sources_data[:openshift][@id2], :missing => true)
      # Multiple create should be also like single create (idempotent)
      assert_openshift_objects_data(sources_data[:amazon][@id3])
      # Multiple update does...multiple updates :)
      assert_openshift_objects_data(changed_source2b)
      # Update of nonexisting should create new one
      assert_openshift_objects_data(new_source)
    end

    it "deletes Sources when supported application removed" do
      subject.add_target('Application', 'destroy', applications_data[@id3])

      stub_api_targeted_init(:source_types      => %i[amazon],
                             :belongs_to        => {:source => [@id3]},
                             :has_one           => {},
                             :request_app_types => false)

      stub_api_applications_get(:request_params => "#{request_filter(:source_id, [@id3])}&#{default_applications_filter}",
                                :response       => list([]),
                                :tenant_header  => user_tenant_header)

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(2)
    end

    it "doesn't delete Source when supported app removed and next exists" do
      subject.add_target('Application', 'destroy', applications_data[@id3])

      stub_api_targeted_init(:source_types      => %i[amazon],
                             :belongs_to        => {:source => [@id3]},
                             :has_one           => {},
                             :request_app_types => false)

      stub_api_applications_get(:request_params => "#{request_filter(:source_id, [@id3])}&#{default_applications_filter}",
                                :response       => list([{'id' => '2', 'application_type_id' => '3', 'source_id' => @id3, 'tenant' => user_tenant_account}]),
                                :tenant_header  => user_tenant_header)

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(3)
    end

    it "Skips Endpoint.destroy when Source was deleted (not synced to Topological db)" do
      id = '7'
      subject.add_target('Endpoint', 'destroy', applications_data[id])

      # Deleted in Sources API, not synced to Topological API yet
      stub_api_common_get('sources', request_filter(:id, [id]), list([sources_by_ids[id]]), user_tenant_header, topology_api)
      stub_api_common_get('sources', request_filter(:id, [id]), list([]), user_tenant_header, sources_api)

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(3)
    end

    it "Skips Endpoint.destroy when Sources was deleted (synced to Topological db)" do
      id = '7'
      subject.add_target('Endpoint', 'destroy', applications_data[id])

      # Deleted in both Sources API, and Topological API
      stub_api_common_get('sources', request_filter(:id, [id]), list([]), user_tenant_header, topology_api)

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(3)
    end

    it "Skips Authentication.destroy when Sources was deleted" do
      id = '7'
      subject.add_target('Authentication', 'destroy', authentications[id])

      # Deleted in Sources API
      stub_api_endpoints_get(:request_params => request_filter(:id, [id]),
                             :response       => list([]))

      subject.sync_targets_with_openshift

      assert_openshift_objects_count(3)
    end
  end

  context "#multitenant targets" do
    it "calls separate API requests per tenant" do
      init_config(:azure => 2) # per collector

      id1, id2 = '7', '13'
      subject.add_target('Source', 'create', sources_data[:azure][id1].merge('availability_status' => 'available'))
      subject.add_target('Source', 'create', sources_data[:azure][id2])

      stub_api_targeted_init(:source_types  => %i[azure],
                             :belongs_to    => {},
                             :has_one       => {:application    => [id1],
                                                :endpoint       => [id1],
                                                :authentication => [id1],
                                                :credentials    => [id1]},
                             :tenant_header => user_tenant_header)
      stub_api_targeted_init(:source_types      => %i[azure],
                             :belongs_to        => {},
                             :has_one           => {:application    => [id2],
                                                    :endpoint       => [id2],
                                                    :authentication => [id2],
                                                    :credentials    => [id2]},
                             :request_app_types => false,
                             :tenant_header     => user2_tenant_header)
      subject.sync_targets_with_openshift

      assert_openshift_objects_count(1)
      assert_openshift_objects_data(sources_data[:azure][id1])
      assert_openshift_objects_data(sources_data[:azure][id2])
    end
  end
end
