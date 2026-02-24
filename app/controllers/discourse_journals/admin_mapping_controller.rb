# frozen_string_literal: true

module DiscourseJournals
  class AdminMappingController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # POST /admin/journals/mapping/analyze
    def analyze
      if MappingAnalysis.has_active?
        return render_json_error("已有映射分析任务正在进行中")
      end

      MappingAnalysis.where.not(status: %i[pending processing]).delete_all

      analysis = MappingAnalysis.create!(
        user_id: current_user.id,
        status: :pending,
      )

      Jobs.enqueue(
        Jobs::DiscourseJournals::AnalyzeMapping,
        analysis_id: analysis.id,
        user_id: current_user.id,
      )

      render json: {
        status: "started",
        analysis_id: analysis.id,
        message: "映射分析任务已启动...",
      }, status: :created
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to start: #{e.message}")
      render_json_error("启动映射分析失败: #{e.message}")
    end

    # GET /admin/journals/mapping/status
    def status
      analysis = MappingAnalysis.current

      if analysis.nil?
        return render_json_dump({ has_analysis: false })
      end

      render_json_dump({
        has_analysis: true,
        analysis: serialize_analysis(analysis),
      })
    end

    # POST /admin/journals/mapping/pause
    def pause
      analysis = MappingAnalysis.current

      unless analysis&.processing?
        return render_json_error("当前没有正在运行的分析任务")
      end

      analysis.update!(status: :paused)
      render json: { status: "paused", message: "分析已暂停" }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to pause: #{e.message}")
      render_json_error("暂停失败: #{e.message}")
    end

    # POST /admin/journals/mapping/restart
    def restart
      current = MappingAnalysis.current

      if current&.processing?
        return render_json_error("请先暂停当前分析任务")
      end

      # 清除所有旧的分析记录
      MappingAnalysis.delete_all

      analysis = MappingAnalysis.create!(
        user_id: current_user.id,
        status: :pending,
      )

      Jobs.enqueue(
        Jobs::DiscourseJournals::AnalyzeMapping,
        analysis_id: analysis.id,
        user_id: current_user.id,
      )

      render json: {
        status: "started",
        analysis_id: analysis.id,
        message: "映射分析已重新启动...",
      }, status: :created
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to restart: #{e.message}")
      render_json_error("重新启动失败: #{e.message}")
    end

    # POST /admin/journals/mapping/apply
    def apply
      analysis = MappingAnalysis.current

      unless analysis&.can_apply?
        return render_json_error("当前没有可以应用的分析结果（需要分析已完成且未在应用中）")
      end

      analysis.update!(
        apply_status: :not_applied,
        apply_error_message: nil,
        apply_stats: {},
        apply_checkpoint: {},
      )

      Jobs.enqueue(
        Jobs::DiscourseJournals::ApplyMapping,
        analysis_id: analysis.id,
        user_id: current_user.id,
      )

      render json: {
        status: "started",
        analysis_id: analysis.id,
        message: "映射应用任务已启动...",
      }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to start apply: #{e.message}")
      render_json_error("启动映射应用失败: #{e.message}")
    end

    # GET /admin/journals/mapping/apply_status
    def apply_status
      analysis = MappingAnalysis.current

      if analysis.nil?
        return render_json_dump({ has_analysis: false })
      end

      render_json_dump({
        has_analysis: true,
        apply_status: analysis.apply_status,
        apply_stats: analysis.apply_stats || {},
        apply_error_message: analysis.apply_error_message,
        apply_started_at: analysis.apply_started_at,
        apply_completed_at: analysis.apply_completed_at,
      })
    end

    # POST /admin/journals/mapping/apply_pause
    def apply_pause
      analysis = MappingAnalysis.current

      unless analysis&.sync_processing?
        return render_json_error("当前没有正在运行的应用任务")
      end

      analysis.update!(apply_status: :sync_paused)

      MessageBus.publish(
        "/journals/mapping-apply",
        {
          analysis_id: analysis.id,
          status: "paused",
          progress: 0,
          message: "应用已暂停",
          stats: analysis.apply_stats || {},
        },
        user_ids: [current_user.id],
      )

      render json: { status: "paused", message: "应用已暂停" }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to pause apply: #{e.message}")
      render_json_error("暂停应用失败: #{e.message}")
    end

    # POST /admin/journals/mapping/apply_resume
    def apply_resume
      analysis = MappingAnalysis.current

      unless analysis&.can_resume_apply?
        return render_json_error("当前没有可以恢复的应用任务（需要处于暂停或失败状态）")
      end

      Jobs.enqueue(
        Jobs::DiscourseJournals::ApplyMapping,
        analysis_id: analysis.id,
        user_id: current_user.id,
        resume: true,
      )

      render json: {
        status: "resuming",
        analysis_id: analysis.id,
        message: "映射应用正在恢复...",
      }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to resume apply: #{e.message}")
      render_json_error("恢复应用失败: #{e.message}")
    end

    # POST /admin/journals/mapping/apply_reset
    def apply_reset
      analysis = MappingAnalysis.current

      unless analysis
        return render_json_error("没有可以重置的分析记录")
      end

      analysis.reset_apply!
      render json: { status: "reset", message: "应用状态已重置" }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to reset apply: #{e.message}")
      render_json_error("重置应用失败: #{e.message}")
    end

    # DELETE /admin/journals/delete_all
    def delete_all
      Jobs.enqueue(Jobs::DiscourseJournals::DeleteAllJournals, user_id: current_user.id)
      render json: { status: "started", message: "删除任务已启动..." }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Mapping] Failed to start delete_all: #{e.message}")
      render_json_error("启动删除失败: #{e.message}")
    end

    # GET /admin/journals/mapping/details?category=exact_1to1&page=1
    def details
      analysis = MappingAnalysis.current

      if analysis.nil?
        return render_json_error("没有分析结果")
      end

      category = params[:category].to_s
      unless MappingAnalysis::CATEGORIES.include?(category)
        return render_json_error("无效的分类: #{category}")
      end

      page = (params[:page] || 1).to_i
      per_page = (params[:per_page] || 50).to_i.clamp(1, 200)

      result = analysis.details_for(category, page: page, per_page: per_page)

      render_json_dump({
        category: category,
        items: result[:items],
        total: result[:total],
        page: result[:page],
        per_page: result[:per_page],
        total_pages: result[:total_pages],
      })
    end

    private

    def serialize_analysis(analysis)
      {
        id: analysis.id,
        status: analysis.status,
        total_forum_topics: analysis.total_forum_topics,
        total_api_records: analysis.total_api_records,
        exact_1to1: analysis.exact_1to1_count,
        forum_1_to_api_n: analysis.forum_1_to_api_n_count,
        forum_n_to_api_1: analysis.forum_n_to_api_1_count,
        forum_n_to_api_m: analysis.forum_n_to_api_m_count,
        forum_only: analysis.forum_only_count,
        api_only: analysis.api_only_count,
        error_message: analysis.error_message,
        started_at: analysis.started_at,
        completed_at: analysis.completed_at,
        created_at: analysis.created_at,
        apply_status: analysis.apply_status,
        apply_stats: analysis.apply_stats || {},
        apply_error_message: analysis.apply_error_message,
        apply_started_at: analysis.apply_started_at,
        apply_completed_at: analysis.apply_completed_at,
      }
    end
  end
end
