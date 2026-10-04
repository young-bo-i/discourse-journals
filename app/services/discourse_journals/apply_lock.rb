# frozen_string_literal: true

module DiscourseJournals
  # Lets one mapping apply run at a time. Two appliers working the same plan
  # each create every planned journal, so one upstream record ends up with
  # several topics. The lease is renewed while the job runs and lapses by
  # itself when the process dies, which lets Resume start a new run.
  class ApplyLock
    KEY = "discourse_journals_apply_lock"
    TTL = 5.minutes
    RENEW_INTERVAL = 1.minute

    RENEW_SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("pexpire", KEYS[1], ARGV[2])
      end
      return 0
    LUA

    RELEASE_SCRIPT = DiscourseRedis::EvalHelper.new <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("del", KEYS[1])
      end
      return 0
    LUA

    def self.held?
      Discourse.redis.exists?(KEY)
    end

    # Runs the block while holding the lease and returns true. Returns false
    # without running it when another apply holds the lease. `on_renew` runs
    # on a background thread after every renewal.
    def self.synchronize(on_renew: nil)
      token = SecureRandom.hex(16)
      return false if !Discourse.redis.set(KEY, token, nx: true, ex: TTL.to_i)

      stop = Queue.new
      renewer = start_renewer(token, stop, on_renew)
      begin
        yield
      ensure
        stop << :stop
        renewer.join
        RELEASE_SCRIPT.eval(Discourse.redis, [Discourse.redis.namespace_key(KEY)], [token])
      end
      true
    end

    def self.start_renewer(token, stop, on_renew)
      db = RailsMultisite::ConnectionManagement.current_db

      Thread.new do
        RailsMultisite::ConnectionManagement.with_connection(db) do
          until stop.pop(timeout: RENEW_INTERVAL.to_f)
            break if !renew(token)

            begin
              ActiveRecord::Base.connection_pool.with_connection { on_renew&.call }
            rescue StandardError => e
              Rails.logger.warn("[DiscourseJournals::ApplyLock] Heartbeat failed: #{e.message}")
            end
          end
        end
      end
    end

    # False only when the lease now belongs to someone else. A Redis error
    # keeps the renewer going so the next tick can retry.
    def self.renew(token)
      RENEW_SCRIPT
        .eval(
          Discourse.redis,
          [Discourse.redis.namespace_key(KEY)],
          [token, TTL.in_milliseconds.to_i],
        )
        .to_i
        .positive?
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals::ApplyLock] Renewal failed: #{e.message}")
      true
    end
    private_class_method :start_renewer, :renew
  end
end
