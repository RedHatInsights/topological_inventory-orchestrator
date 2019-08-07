describe TopologicalInventory::Orchestrator::ObjectManager do
  context "#create_deployment_config" do
    let(:instance)    { described_class.new }
    let(:kube_client) { double("Kubeclient::Client") }
    let(:quota)       { Kubeclient::Resource.new(:kind => "ResourceQuota", :status => status) }
    let(:status)      { Kubeclient::Resource.new(:hard => status_hard, :used => status_used) }
    let(:status_hard) { Kubeclient::Resource.new("limits.cpu" => "8", "limits.memory" => "16Gi", "requests.cpu" => "4", "requests.memory" => "8Gi") }
    let(:status_used) { Kubeclient::Resource.new("limits.cpu" => "3600m", "limits.memory" => "13172Mi", "requests.cpu" => "1600m", "requests.memory" => "6200Mi") }

    before do
      expect(instance).to receive(:kube_connection).and_return(kube_client)
      expect(kube_client).to receive(:get_resource_quota).with("compute-resources-non-terminating", nil).and_return(quota)
    end

    it "quota allows" do
      expect(instance).to receive(:connection).and_return(kube_client)
      expect(kube_client).to receive(:create_deployment_config)

      instance.create_deployment_config("test_name", "test_namespace", "test_image")
    end

    it "exceeds cpu limit" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "test_namespace", "test_image") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:limits][:cpu] = "7000m"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaCpuLimitExceeded)
    end

    it "exceeds cpu requests" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "test_namespace", "test_image") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:requests][:cpu] = "3000m"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaCpuRequestExceeded)
    end

    it "exceeds memory limit" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "test_namespace", "test_image") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:limits][:memory] = "4000Mi"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaMemoryLimitExceeded)
    end

    it "exceeds memory requests" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "test_namespace", "test_image") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:requests][:memory] = "3000Mi"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaMemoryRequestExceeded)
    end
  end
end
