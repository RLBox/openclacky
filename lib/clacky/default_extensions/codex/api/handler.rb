# frozen_string_literal: true

require_relative "../codex_home"
require_relative "../launcher"

# Safe readiness endpoint for the bundled Codex provider. Authentication and
# ACP session actions are added by the runtime implementation slice.
class CodexExt < Clacky::ApiExtension
  class << self
    def status_payload(home_result:, launcher_result:)
      payload = {
        available: launcher_result.available?,
        status: launcher_result.available? ? "ready" : "unavailable",
        authenticated: nil,
        auth_reused: home_result.auth_reused == true,
        auth_reason: home_result.auth_reason
      }
      payload[:launcher] = launcher_result.source.to_s if launcher_result.source
      payload[:version] = launcher_result.version if launcher_result.version
      payload[:error_code] = launcher_result.error_code if launcher_result.error_code
      payload[:message] = launcher_result.message if launcher_result.message
      payload
    end
  end

  get "/status" do
    home_result = Clacky::DefaultExtensions::Codex::CodexHome.new.prepare
    launcher_result = Clacky::DefaultExtensions::Codex::Launcher.new(
      codex_home: home_result.managed_home
    ).resolve
    json(self.class.status_payload(
      home_result: home_result,
      launcher_result: launcher_result
    ))
  rescue Clacky::DefaultExtensions::Codex::CodexHome::Error
    json(
      available: false,
      status: "unavailable",
      authenticated: nil,
      auth_reused: false,
      auth_reason: "managed_home_error",
      error_code: "managed_home_error",
      message: "OpenClacky could not prepare the managed Codex home."
    )
  end
end
