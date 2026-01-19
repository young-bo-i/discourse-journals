# frozen_string_literal: true

DiscourseJournals::Engine.routes.draw do
  scope "/admin/plugins/journals", constraints: AdminConstraint.new do
    scope format: false do
      get "/" => "admin#index"
    end

    scope format: :json do
      post "/imports" => "admin_imports#create"
    end
  end
end

Discourse::Application.routes.draw { mount ::DiscourseJournals::Engine, at: "/" }
