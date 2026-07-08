# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ImportPersonas < ::Jobs::Base
      sidekiq_options retry: 0, queue: "low"

      BATCH_SIZE = 500

      def execute(args)
        import_id = args[:import_id]
        user_id = args[:user_id]

        import = ::DiscourseJournals::PersonaImport.find_by(id: import_id)
        return unless import
        return if import.completed? || import.failed?

        import.update!(status: :processing, started_at: Time.current)

        rows = import.rows_data || []
        total = rows.size
        group = ::DiscourseJournals::PersonaPool.ensure_group!
        floor = ::User.human_users.minimum(:created_at)
        builder = ::DiscourseJournals::PersonaBuilder.new(group: group, floor: floor)

        stats = { "created" => 0, "skipped" => 0, "errors" => 0 }
        errors_sample = []

        rows.each_slice(BATCH_SIZE).with_index do |batch, batch_idx|
          batch.each { |row| build_row(builder, row, stats, errors_sample) }

          processed = [(batch_idx + 1) * BATCH_SIZE, total].min
          import.update_columns(stats: stats)
          publish(user_id, import, "processing", processed, total, stats)
        end

        ::DiscourseJournals::PersonaPool.exclude_from_leaderboards!

        import.update!(
          status: :completed,
          completed_at: Time.current,
          stats: stats.merge("errors_sample" => errors_sample),
          rows_data: [],
        )
        publish(user_id, import, "completed", total, total, stats)
      rescue StandardError => e
        Rails.logger.error(
          "[DiscourseJournals::ImportPersonas] failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}",
        )
        if import
          import.update!(status: :failed, error_message: e.message, completed_at: Time.current)
          publish(user_id, import, "failed", 0, import.total, import.stats || {})
        end
      end

      private

      def build_row(builder, row, stats, errors_sample)
        result = builder.build!(row)
        stats["created"] += 1 if result == :created
        stats["skipped"] += 1 if result == :skipped
      rescue ::DiscourseJournals::PersonaBuilder::SkipRow => e
        stats["skipped"] += 1
        errors_sample << e.message if errors_sample.size < 50
      rescue StandardError => e
        stats["errors"] += 1
        errors_sample << "#{row["username"]}: #{e.message}" if errors_sample.size < 50
        Rails.logger.warn("[DiscourseJournals::ImportPersonas] row failed: #{e.class}: #{e.message}")
      end

      def publish(user_id, import, status, processed, total, stats)
        return unless user_id

        MessageBus.publish(
          "/journals/persona-import",
          {
            import_id: import.id,
            status: status,
            processed: processed,
            total: total,
            progress: total > 0 ? (processed * 100.0 / total).round : 0,
            stats: stats,
          },
          user_ids: [user_id],
        )
      end
    end
  end
end
