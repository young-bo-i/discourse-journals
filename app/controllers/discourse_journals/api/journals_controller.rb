# frozen_string_literal: true

module DiscourseJournals
  module Api
    class JournalsController < ::ApplicationController
      requires_plugin DiscourseJournals::PLUGIN_NAME
      
      before_action :ensure_staff
      skip_before_action :verify_authenticity_token, if: :is_api_request?

      # POST /discourse-journals/api/journals/batch
      # 批量导入期刊（不需要文件）
      def batch_create
        journals = params[:journals]
        
        unless journals.is_a?(Array)
          return render_json_error("journals 参数必须是数组", status: 400)
        end

        if journals.empty?
          return render_json_error("journals 数组不能为空", status: 400)
        end

        if journals.size > 500
          return render_json_error("单次最多导入 500 个期刊，当前: #{journals.size}", status: 400)
        end

        Rails.logger.info("[DiscourseJournals::API] Batch import started: #{journals.size} journals, user: #{current_user.username}")

        results = {
          total: journals.size,
          created: 0,
          updated: 0,
          skipped: 0,
          errors: []
        }

        journals.each_with_index do |journal_data, index|
          begin
            result = process_journal(journal_data)
            case result
            when :created
              results[:created] += 1
            when :updated
              results[:updated] += 1
            when :skipped
              results[:skipped] += 1
            end
          rescue StandardError => e
            error_msg = "索引 #{index}: #{e.message}"
            results[:errors] << error_msg
            results[:skipped] += 1
            Rails.logger.error("[DiscourseJournals::API] #{error_msg}")
          end
        end

        Rails.logger.info("[DiscourseJournals::API] Batch import completed: #{results}")

        render json: {
          success: true,
          results: results,
          message: "导入完成：#{results[:created]} 新建，#{results[:updated]} 更新，#{results[:skipped]} 跳过"
        }
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals::API] Batch import failed: #{e.message}\n#{e.backtrace.join("\n")}")
        render_json_error("批量导入失败: #{e.message}", status: 500)
      end

      # GET /discourse-journals/api/journals/:issn
      # 查询期刊
      def show
        issn = params[:issn]
        
        topic = Topic.joins(:_custom_fields)
          .where("topic_custom_fields.name = ? AND topic_custom_fields.value = ?", 
                 DiscourseJournals::CUSTOM_FIELD_ISSN, issn)
          .first

        if topic.blank?
          return render_json_error("期刊不存在: #{issn}", status: 404)
        end

        render json: {
          success: true,
          journal: {
            issn: topic.custom_fields[DiscourseJournals::CUSTOM_FIELD_ISSN],
            name: topic.custom_fields[DiscourseJournals::CUSTOM_FIELD_NAME],
            topic_id: topic.id,
            topic_url: topic.url,
            created_at: topic.created_at,
            updated_at: topic.updated_at
          }
        }
      end

      private

      def process_journal(journal_data)
        primary_issn = journal_data["primary_issn"] || journal_data[:primary_issn]
        if primary_issn.blank?
          raise ArgumentError, "Missing primary_issn"
        end

        unified_index = journal_data["unified_index"] || journal_data[:unified_index] || {}
        title = unified_index["title"] || unified_index[:title]
        if title.blank?
          raise ArgumentError, "Missing title in unified_index"
        end

        journal_params = {
          issn: primary_issn,
          name: title,
          unified_index: unified_index,
          aliases: journal_data["aliases"] || journal_data[:aliases] || [],
          sources: extract_sources(journal_data["sources_by_provider"] || journal_data[:sources_by_provider] || {})
        }

        upserter = JournalUpserter.new(system_user: Discourse.system_user)
        upserter.upsert!(journal_params)
      end

      def extract_sources(sources_by_provider)
        {
          crossref: sources_by_provider.dig("crossref", "data") || sources_by_provider.dig(:crossref, :data),
          doaj: sources_by_provider.dig("doaj", "data") || sources_by_provider.dig(:doaj, :data),
          nlm: sources_by_provider.dig("nlm", "data") || sources_by_provider.dig(:nlm, :data),
          openalex: sources_by_provider.dig("openalex", "data") || sources_by_provider.dig(:openalex, :data),
          wikidata: sources_by_provider.dig("wikidata", "data") || sources_by_provider.dig(:wikidata, :data)
        }
      end

      def is_api_request?
        request.headers["Api-Key"].present? || request.headers["HTTP_API_KEY"].present?
      end
    end
  end
end
