# frozen_string_literal: true

module DiscourseJournals
  class AdminMappingController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # POST /admin/journals/mapping/analyze
    def analyze
      if MappingAnalysis.has_active?
        return render_json_error("已有映射分析任务正在进行中")
      end

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
      }
    end
  end
end
