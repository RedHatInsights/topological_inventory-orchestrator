describe TopologicalInventory::Orchestrator::Worker do
  include Functions

  let(:kube_client) { TopologicalInventory::Orchestrator::TestModels::KubeClient.new }
  let(:object_manager) { TopologicalInventory::Orchestrator::TestModels::ObjectManager.new(kube_client) }

  # Predefined responses
  let(:empty_list_response) { list([]) }
  let(:tenants_response) { list([tenants[user_tenant_account]]) }
  let(:source_types_response) { list(source_types_data.values) }
  let(:application_types_response) { list(application_types_data) }
  let(:applications_response) { list(applications_data.values) }

  subject do
    allow(described_class).to receive(:path_to_config).and_return(File.expand_path("../config", File.dirname(__FILE__)))
    described_class.new(:sources_api => sources_api, :topology_api => topology_api)
  end

  before do
    # Clear cache
    TopologicalInventory::Orchestrator::Api.class_variable_set :@@cache_start, nil

    # Turn off logger
    allow(TopologicalInventory::Orchestrator).to receive(:logger).and_return(double('logger').as_null_object)

    # Get testing object_manager/kube_client
    allow(subject).to receive(:object_manager).and_return(object_manager)
  end

  describe "#quotas" do
    let(:topology_sources_response) { list(topological_sources[:openshift].values) }
    let(:available_sources_size) { available_sources_data(:openshift).keys.size }

    before do
      # Init of api calls
      stub_api_init(:application_types => application_types_response,
                    :applications      => applications_response,
                    :source_types      => source_types_response,
                    :tenants           => tenants_response,
                    :topology_sources  => topology_sources_response)
      init_config
    end

    it "successful" do
      # Init Source API calls
      sources_data[:openshift].each_value do |source_data|
        stub_api_source_calls(source_data)
        stub_api_source_refresh_status_patch(source_data, "deployed") if source_available?(source_data)
      end

      expect(subject.send(:object_manager)).to receive(:check_deployment_config_quota).exactly(available_sources_size).times
      # Run orchestrator
      subject.send(:make_openshift_match_database)

      # Test number of objects in OpenShift
      assert_openshift_objects_count(available_sources_size)
    end

    it "failed quota check" do
      # Init Source API calls
      sources_data[:openshift].each_value do |source_data|
        stub_api_source_calls(source_data)
        stub_api_source_refresh_status_patch(source_data, "quota_limited") if source_available?(source_data)
      end

      expect(subject.send(:object_manager)).to receive(:check_deployment_config_quota).and_raise(::TopologicalInventory::Orchestrator::ObjectManager::QuotaCpuLimitExceeded).exactly(available_sources_size).times

      expect(kube_client).not_to receive(:create_deployment_config)

      # Run orchestrator
      subject.send(:make_openshift_match_database)

      assert_openshift_objects_count(0)
    end
  end

  describe "#remove_deprecated_objects" do
    before do
      init_config(:version => 'v2')
      %w[v1 v2 v0].each do |version|
        object_manager.create_config_map("config_map_#{version}") do |map|
          map[:metadata][:labels][TopologicalInventory::Orchestrator::ConfigMap::LABEL_COMMON] = version
        end
        object_manager.create_secret("secret_#{version}", {}) do |secret|
          secret[:metadata][:labels][TopologicalInventory::Orchestrator::Secret::LABEL_COMMON] = version
        end
        object_manager.create_deployment_config("dc_#{version}", "openshift") do |dc|
          dc[:metadata][:labels][TopologicalInventory::Orchestrator::DeploymentConfig::LABEL_COMMON] = version
        end
      end
    end

    it "removes objects v0 and v1, keeps v2" do
      expect(kube_client.config_maps.size).to eq(3)
      expect(kube_client.deployment_configs.size).to eq(3)
      expect(kube_client.secrets.size).to eq(3)

      subject.send(:remove_deprecated_objects)

      expect(kube_client.config_maps.size).to eq(1)
      expect(kube_client.deployment_configs.size).to eq(1)
      expect(kube_client.secrets.size).to eq(1)

      label = TopologicalInventory::Orchestrator::ConfigMap::LABEL_COMMON
      expect(object_manager.get_config_maps(label).first.metadata.labels[label]).to eq('v2')
      label = TopologicalInventory::Orchestrator::DeploymentConfig::LABEL_COMMON
      expect(object_manager.get_deployment_configs(label).first.metadata.labels[label]).to eq('v2')
      label = TopologicalInventory::Orchestrator::Secret::LABEL_COMMON
      expect(object_manager.get_secrets(label).first.metadata.labels[label]).to eq('v2')
    end
  end
end
