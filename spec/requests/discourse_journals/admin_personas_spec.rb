# frozen_string_literal: true

describe DiscourseJournals::AdminPersonasController do
  before { enable_current_plugin }

  fab!(:admin)

  def csv_upload(content, filename = "personas.csv")
    file = Tempfile.new(["personas", File.extname(filename)])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: filename)
  end

  describe "POST /admin/journals/personas/import" do
    it "parses the upload and creates an import record with the parsed rows" do
      sign_in(admin)

      post "/admin/journals/personas/import.json",
           params: {
             file: csv_upload("username,name\nwei.zhang,Zhang Wei\nmchen,\n"),
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["total"]).to eq(2)
      expect(DiscourseJournals::PersonaImport.last.total).to eq(2)
    end

    it "returns an error for a file with no username column" do
      sign_in(admin)

      post "/admin/journals/personas/import.json", params: { file: csv_upload("name\nSomeone\n") }

      expect(response.status).to eq(422)
    end

    it "denies non-admins" do
      sign_in(Fabricate(:user))

      post "/admin/journals/personas/import.json", params: {}

      expect(response.status).to eq(404)
    end
  end

  describe "GET /admin/journals/personas/status" do
    it "returns the current persona count for admins" do
      sign_in(admin)

      get "/admin/journals/personas/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body).to have_key("persona_count")
    end
  end
end
