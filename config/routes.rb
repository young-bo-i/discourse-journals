# frozen_string_literal: true

DiscourseJournals::Engine.routes.draw do
  scope "/admin/journals", constraints: AdminConstraint.new do
    get "/" => "admin#index"
    post "/imports" => "admin_imports#create"
  end
end

Discourse::Application.routes.draw { mount ::DiscourseJournals::Engine, at: "/" }
