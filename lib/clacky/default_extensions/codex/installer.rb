# frozen_string_literal: true

require "net/http"
require "open3"
require "tempfile"
require "uri"

module Clacky
  module DefaultExtensions
    module Codex
      # Installs the official standalone Codex CLI after an explicit UI action.
      class Installer
        INSTALLER_URL = "https://chatgpt.com/codex/install.sh"
        MAX_SCRIPT_BYTES = 2 * 1024 * 1024
        MAX_REDIRECTS = 3
        # chatgpt.com is the stable public entry point; it currently redirects
        # to OpenAI's dedicated release host. Keep this list exact so a
        # compromised redirect cannot turn the installer into an arbitrary
        # script downloader.
        ALLOWED_HOSTS = %w[
          chatgpt.com
          www.chatgpt.com
          releases.openai.com
        ].freeze
        CHECKSUM_DOWNLOAD = <<~'SH'.strip
          download_file_with_fallback "$checksum_url" "$checksum_fallback_url" "$checksum_path" "$checksum_digest" "$checksum_asset" "$asset"
        SH

        Result = Struct.new(:ok, :message, :error_code, keyword_init: true)

        def initialize(http_get: nil, command_runner: nil)
          @http_get = http_get || method(:download)
          @command_runner = command_runner || method(:run_script)
        end

        def install
          script = @http_get.call(URI(INSTALLER_URL))
          return failure("installer_download_failed", "Could not download the official Codex installer.") if script.to_s.empty?
          return failure("installer_too_large", "The Codex installer response was unexpectedly large.") if script.bytesize > MAX_SCRIPT_BYTES

          Tempfile.create(["openclacky-codex-installer", ".sh"]) do |file|
            file.chmod(0o600)
            file.binmode
            file.write(prepare_script(script))
            file.flush
            stdout, stderr, status = @command_runner.call(file.path)
            unless status.success?
              detail = [stderr, stdout].flat_map do |stream|
                stream.to_s.lines.last(3)
              end.join.strip
              message = "Codex CLI installation failed."
              message = "#{message} #{detail}" unless detail.empty?
              return failure("installer_failed", message.byteslice(0, 800))
            end
          end
          Result.new(ok: true, message: "Codex CLI was installed.")
        rescue StandardError
          failure("installer_failed", "Codex CLI installation failed.")
        end

        private def download(uri, redirects = 0)
          raise "too many redirects" if redirects > MAX_REDIRECTS
          raise "unexpected installer host" unless uri.is_a?(URI::HTTPS) && ALLOWED_HOSTS.include?(uri.host)

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: 10,
            read_timeout: 60
          ) { |http| http.get(uri.request_uri) }
          if response.is_a?(Net::HTTPRedirection)
            target = URI.join(uri, response.fetch("location"))
            return download(target, redirects + 1)
          end
          raise "installer download failed" unless response.is_a?(Net::HTTPSuccess)
          raise "installer too large" if response.body.to_s.bytesize > MAX_SCRIPT_BYTES

          response.body.to_s
        end

        private def run_script(filename)
          environment = ENV.to_h.reject do |key, _value|
            %w[CODEX_HOME CODEX_CONFIG OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN].include?(key)
          end
          environment["CODEX_NON_INTERACTIVE"] = "true"
          Open3.capture3(
            environment,
            ["/bin/sh", "/bin/sh"],
            filename,
            unsetenv_others: true
          )
        end

        # The standalone installer published on 2026-09-16 invokes the
        # checksum download in the current shell. Its helper functions use
        # global POSIX-shell variables and overwrite the outer archive_path,
        # causing the large package to be downloaded to the checksum path.
        # Isolate that exact call. If OpenAI changes the script shape, leave it
        # untouched rather than applying a broad or ambiguous rewrite.
        private def prepare_script(script)
          return script unless script.include?(CHECKSUM_DOWNLOAD)

          script.sub(CHECKSUM_DOWNLOAD, "( #{CHECKSUM_DOWNLOAD} )")
        end

        private def failure(error_code, message)
          Result.new(ok: false, error_code: error_code, message: message)
        end
      end
    end
  end
end
