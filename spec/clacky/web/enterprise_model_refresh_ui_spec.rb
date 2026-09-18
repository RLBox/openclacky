# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Enterprise model refresh UI" do
  let(:web_root) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:index) { File.read(File.join(web_root, "index.html")) }
  let(:settings) { File.read(File.join(web_root, "settings.js")) }
  let(:app) { File.read(File.join(web_root, "app.js")) }
  let(:refresh_client) { File.read(File.join(web_root, "enterprise-models.js")) }

  it "offers an explicit refresh action on the enterprise license card" do
    expect(index).to include('id="btn-refresh-enterprise-models"')
    expect(index).to include('id="enterprise-model-refresh-status"')
    expect(settings).to include("EnterpriseModels.refresh({ force: true")
  end

  it "refreshes quietly on boot and when the app becomes visible again" do
    expect(index).to include('<script src="/enterprise-models.js"></script>')
    expect(refresh_client).to include('fetch("/api/enterprise/models/refresh"')
    expect(refresh_client).to include('document.addEventListener("visibilitychange"')
    expect(app).to include("EnterpriseModels.start()")
  end

  it "renders a read-only enterprise-only model experience" do
    expect(index).to include('id="personal-byok-policy-notice"')
    expect(settings).to include('configData.personal_byok_allowed !== false')
    expect(settings).to include('model.enterprise_managed === true')
    expect(settings).to include('src === "custom" && !_personalByokAllowed')
  end
end
