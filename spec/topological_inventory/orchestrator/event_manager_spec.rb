RSpec.describe TopologicalInventory::Orchestrator::EventManager do
  let(:worker) { double("worker") }
  let(:message) { double("Message") }
  let(:queue) { double("Queue") }

  subject { described_class.new(worker) }

  before do
    # Turn off logger
    allow(TopologicalInventory::Orchestrator).to receive(:logger).and_return(double('logger').as_null_object)

    allow(subject).to receive(:sleep)
    allow(subject).to receive(:queue).and_return(queue)
    allow(message).to receive(:payload).and_return('id' => '1')
  end

  describe "#event_listener" do
    let(:messaging_client) { double("Kafka Client") }

    before do
      allow(subject).to receive(:messaging_client).and_return(messaging_client)
      allow(messaging_client).to receive(:subscribe_topic) do |_, &block|
        block.call(message)
      end
      allow(messaging_client).to receive(:close)
    end

    it "processes only allowed events" do
      expect(queue).to receive(:push).exactly(2).times

      # 2 supported and 2 unsupported events
      %w[Source.create
         Source.custom
         Not.interesting.event
         Application.create].each do |event_name|
        allow(message).to receive(:message).and_return(event_name)
        subject.send(:event_listener)
      end
    end
  end
end
