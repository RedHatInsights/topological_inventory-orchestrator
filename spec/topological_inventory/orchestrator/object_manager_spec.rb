describe TopologicalInventory::Orchestrator::ObjectManager do
  context "#create_deployment_config" do
    let(:instance)    { described_class.new }
    let(:kube_client) { double("Kubeclient::Client") }
    let(:quota)       { Kubeclient::Resource.new(:kind => "ResourceQuota", :status => status) }
    let(:status)      { Kubeclient::Resource.new(:hard => status_hard, :used => status_used) }
    let(:status_hard) { Kubeclient::Resource.new("limits.cpu" => "8", "limits.memory" => "16Gi", "requests.cpu" => "4", "requests.memory" => "8Gi") }
    let(:status_used) { Kubeclient::Resource.new("limits.cpu" => "3600m", "limits.memory" => "13172Mi", "requests.cpu" => "1600m", "requests.memory" => "6200Mi") }

    before do
      allow(instance).to receive(:kube_connection).and_return(kube_client)
      allow(kube_client).to receive(:get_resource_quota).with("compute-resources-non-terminating", nil).and_return(quota)
      allow(instance).to receive(:get_collector_image).with("ansible-tower").and_return("quay.io/ansible-tower:abcdefg")
    end

    it "quota allows" do
      expect(instance).to receive(:connection).and_return(kube_client)
      expect(kube_client).to receive(:create_deployment_config)

      instance.create_deployment_config("test_name", "ansible-tower")
    end

    it "exceeds cpu limit" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "ansible-tower") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:limits][:cpu] = "7000m"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaCpuLimitExceeded)
    end

    it "exceeds cpu requests" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "ansible-tower") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:requests][:cpu] = "3000m"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaCpuRequestExceeded)
    end

    it "exceeds memory limit" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "ansible-tower") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:limits][:memory] = "4000Mi"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaMemoryLimitExceeded)
    end

    it "exceeds memory requests" do
      expect(kube_client).not_to receive(:create_deployment_config)

      expect do
        instance.create_deployment_config("test_name", "ansible-tower") do |deployment|
          deployment[:spec][:template][:spec][:containers].first[:resources][:requests][:memory] = "3000Mi"
        end
      end.to raise_error(TopologicalInventory::Orchestrator::ObjectManager::QuotaMemoryRequestExceeded)
    end
  end

  describe "#detect_openshift_connection (private)" do
    let(:instance)          { described_class.new }
    let(:kube_service_host) { "kube.example.com" }
    let(:kube_service_port) { 123 }
    let(:v3_connection)     { instance_double(Kubeclient::Client, "v3_connection") }
    let(:v4_connection)     { instance_double(Kubeclient::Client, "v4_connection") }

    let(:v3_uri) do
      URI::HTTPS.build(
        :host => kube_service_host,
        :port => kube_service_port,
        :path => "/oapi"
      )
    end

    let(:v4_uri) do
      URI::HTTPS.build(
        :host => kube_service_host,
        :port => kube_service_port,
        :path => "/apis/apps.openshift.io"
      )
    end

    let(:kube_resource_error) do
      Kubeclient::ResourceNotFoundError.new(404, "not found", nil)
    end

    around do |example|
      host = ENV["KUBERNETES_SERVICE_HOST"]
      port = ENV["KUBERNETES_SERVICE_PORT"]
      ENV["KUBERNETES_SERVICE_HOST"] = kube_service_host
      ENV["KUBERNETES_SERVICE_PORT"] = kube_service_port.to_s

      example.run

      ENV["KUBERNETES_SERVICE_HOST"] = host
      ENV["KUBERNETES_SERVICE_PORT"] = port
    end

    before { expect(instance).to receive(:raw_connect).with(v3_uri).and_return(v3_connection) }

    it "returns the v3 connection when it is available" do
      expect(v3_connection).to receive(:discover).and_return(true)
      expect(instance.send(:detect_openshift_connection)).to eq(v3_connection)
    end

    context "when the v3 connection is not available" do
      before do
        expect(v3_connection).to receive(:discover).and_raise(kube_resource_error)
        expect(instance).to receive(:raw_connect).with(v4_uri).and_return(v4_connection)
      end

      it "returns the v4 connection when it is available" do
        expect(v4_connection).to receive(:discover).and_return(true)
        expect(instance.send(:detect_openshift_connection)).to eq(v4_connection)
      end

      it "raises when no connection is available" do
        expect(v4_connection).to receive(:discover).and_raise(kube_resource_error)
        expect { instance.send(:detect_openshift_connection) }.to raise_error(RuntimeError)
      end
    end
  end
end
