# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    # Rewrites every journal first post once per renderer layout version, so a
    # deploy that changes the page markup is not left showing old HTML under
    # the new stylesheet. Progress is saved per batch and picked up by the next
    # run if the process dies.
    #
    # It runs even while a mapping apply does: an apply takes hours to reach
    # every topic, and CookedRerenderer never overwrites a page the apply has
    # already rewritten from newer data.
    class RerenderLayout < ::Jobs::Scheduled
      every 10.minutes
      sidekiq_options queue: "low"

      STATE_KEY = "rendered_layout"
      # About 200 topics a second instead of 700+: a full pass rewrites several
      # GB of cooked HTML, which should not swamp the database's WAL.
      BATCH_PAUSE = 1.5

      def execute(_args)
        return if !SiteSetting.discourse_journals_enabled
        return if SiteSetting.discourse_journals_category_id.to_i.zero?

        target = ::DiscourseJournals::MasterRecordRenderer::LAYOUT_VERSION
        state = PluginStore.get(::DiscourseJournals::PLUGIN_NAME, STATE_KEY) || {}
        return if state["version"].to_i >= target

        after_id = state["target"].to_i == target ? state["after_id"].to_i : 0
        result =
          ::DiscourseJournals::CookedRerenderer
            .new
            .rerender_all!(after_id: after_id, pause: BATCH_PAUSE) do |progress|
              save_state(state.merge("target" => target, "after_id" => progress.last_topic_id))
            end

        save_state(
          "version" => target,
          "completed_at" => Time.zone.now.iso8601,
          "failed" => result.failed,
        )
      end

      private

      def save_state(state)
        PluginStore.set(::DiscourseJournals::PLUGIN_NAME, STATE_KEY, state)
      end
    end
  end
end
