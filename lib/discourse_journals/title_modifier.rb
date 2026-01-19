# frozen_string_literal: true

module DiscourseJournals
  module TitleModifier
    def self.modify_title(topic, title)
      return title unless SiteSetting.discourse_journals_enabled
      return title if SiteSetting.discourse_journals_title_suffix.blank?
      
      category_id = SiteSetting.discourse_journals_category_id
      return title if category_id.blank?
      
      # 检查是否是期刊分类的话题
      if topic.category_id == category_id.to_i
        suffix = SiteSetting.discourse_journals_title_suffix
        # 避免重复添加后缀
        return title if title.include?(suffix)
        
        "#{title} - #{suffix}"
      else
        title
      end
    end
  end
end
