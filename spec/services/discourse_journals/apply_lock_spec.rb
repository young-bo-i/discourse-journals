# frozen_string_literal: true

describe DiscourseJournals::ApplyLock do
  before { Discourse.redis.del(described_class::KEY) }

  describe ".synchronize" do
    it "runs the block while holding the lock and frees it afterwards" do
      held_inside = nil

      expect(described_class.synchronize { held_inside = described_class.held? }).to eq(true)
      expect(held_inside).to eq(true)
      expect(described_class.held?).to eq(false)
    end

    it "skips the block while another apply holds the lock" do
      second_ran = false

      described_class.synchronize do
        expect(described_class.synchronize { second_ran = true }).to eq(false)
      end

      expect(second_ran).to eq(false)
    end

    it "keeps renewing the lease while the block runs" do
      renewals = Queue.new

      stub_const(described_class, :RENEW_INTERVAL, 0.05) do
        described_class.synchronize(on_renew: -> { renewals << :renewed }) do
          expect(renewals.pop(timeout: 2)).to eq(:renewed)
          expect(Discourse.redis.ttl(described_class::KEY)).to be > 0
        end
      end
    end
  end
end
