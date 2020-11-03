describe TopologicalInventory::Orchestrator::HealthCheck do
  let(:object_manager) { double }
  let(:k8s) { double }

  subject do
    described_class.new(
      URI.parse("http://topology:3000/api/topo"),
      URI.parse("http://sources:3000/api/sources"),
      object_manager,
      60
    )
  end

  before do
    allow(object_manager).to receive(:connection).and_return(k8s)
    allow(k8s).to receive(:api_endpoint).and_return("http://k8s.api/oapi")
  end

  context "when everything is available" do
    before do
      allow(Net::HTTP).to receive(:get_response).and_return(OpenStruct.new(:code => 200))
      allow(object_manager).to receive(:connection).and_return(k8s)
      allow(object_manager).to receive(:check_api_status).and_return('{"yes": true}')
    end

    it "touches the healthy file" do
      expect(FileUtils).to receive(:touch).with("/tmp/healthy").once
      expect(object_manager).to receive(:check_api_status).once
      subject.checks
    end
  end

  context "when the apis are not reachable" do
    before do
      allow(Net::HTTP).to receive(:get_response).and_return(OpenStruct.new(:code => 400))
      allow(object_manager).to receive(:check_api_status).and_return('{"yes": true}')
    end

    it "removes the healthy file" do
      expect(FileUtils).to receive(:rm_f).with("/tmp/healthy").once
      subject.checks
    end
  end

  context "when k8s is not reachable" do
    before do
      allow(Net::HTTP).to receive(:get_response).and_return(OpenStruct.new(:code => 200))
      allow(object_manager).to receive(:check_api_status).and_return(nil)
    end

    it "removes the healthy file" do
      expect(FileUtils).to receive(:rm_f).with("/tmp/healthy").once
      subject.checks
    end
  end
end
