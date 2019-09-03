RSpec.describe TopologicalInventory::Orchestrator::EventManager do
  let(:worker) { double("worker") }
  let(:message) { double("Message") }

  subject { described_class.new(worker) }

  before do
    # Turn off logger
    allow(TopologicalInventory::Orchestrator).to receive(:logger).and_return(double('logger').as_null_object)

    allow(subject).to receive(:sleep)
    allow(message).to receive(:payload).and_return('id' => '1')

    @mutex = Mutex.new
    @cv = ConditionVariable.new
    @sync_invoked = 0
  end

  describe "#scheduled_sync" do
    it "doesn't invoke sync in less than hour" do
      subject.send(:last_event_at=, Time.now.utc - 5.minutes)
      expect(subject).not_to receive(:process_event)
      subject.send(:scheduled_sync)
    end

    it "invokes sync after an hour" do
      subject.send(:last_event_at=, Time.now.utc - 1.hour)
      stub_process_event
      subject.send(:scheduled_sync)

      assert_process_event_calls_count(1)
    end

    it "invokes sync when orchestrator starts" do
      subject.send(:last_event_at=, nil)
      stub_process_event
      subject.send(:scheduled_sync)

      assert_process_event_calls_count(1)
    end
  end

  describe "#listener" do
    let(:messaging_client) { double("Kafka Client") }

    before do
      allow(subject).to receive(:messaging_client).and_return(messaging_client)
      allow(messaging_client).to receive(:subscribe_topic) do |_, &block|
        block.call(message)
      end
      allow(messaging_client).to receive(:close)
    end

    it "processes only allowed events" do
      stub_process_event

      # Unsupported events
      allow(message).to receive(:message).and_return("Source.custom")
      subject.send(:listener)
      allow(message).to receive(:message).and_return("Not.interesting.event")
      subject.send(:listener)

      # Supported events
      allow(message).to receive(:message).and_return("Source.create")
      subject.send(:listener)
      allow(message).to receive(:message).and_return("Application.create")
      subject.send(:listener)

      assert_process_event_calls_count(2)
    end

    it "start sync only once for subsequent events" do
      expect(worker).to receive(:make_openshift_match_database).twice

      skip_sync_duration = 1.second
      stub_const("#{subject.class.name}::SKIP_SUBSEQUENT_EVENTS_DURATION", skip_sync_duration)

      2.times do
        allow(message).to receive(:message).and_return("Source.create")
        subject.send(:listener)
        allow(message).to receive(:message).and_return("Endpoint.create")
        subject.send(:listener)
        allow(message).to receive(:message).and_return("Authentication.create")
        subject.send(:listener)

        sleep(skip_sync_duration)
      end
    end
  end

  def stub_process_event
    allow(subject).to receive(:process_event) do
      @mutex.synchronize { @sync_invoked += 1; @cv.wait(@mutex) }
    end
  end

  def assert_process_event_calls_count(expected_cnt)
    called = false
    until called
      @mutex.synchronize { called = expected_cnt == @sync_invoked }
    end
    @cv.broadcast
    expect(expected_cnt).to eq(@sync_invoked)
  end
end
