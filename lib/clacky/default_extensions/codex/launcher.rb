# frozen_string_literal: true

require "open3"

module Clacky
  module DefaultExtensions
    module Codex
      # Locates the official Codex CLI and launches its bundled App Server.
      # The provider deliberately has no Node/npm or third-party adapter dependency.
      class Launcher
        SHELL_ENV_EXCLUDE = %w[
          CODEX_HOME CODEX_CONFIG CODEX_PATH
          OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN
          AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
          AZURE_CLIENT_SECRET GOOGLE_APPLICATION_CREDENTIALS
          GITHUB_TOKEN GH_TOKEN NPM_TOKEN SSH_AUTH_SOCK NODE_OPTIONS
        ].freeze
        SAFE_ENV_KEYS = %w[
          PATH Path HOME USER LOGNAME SHELL LANG LANGUAGE LC_ALL
          TMPDIR TMP TEMP TZ PATHEXT SYSTEMROOT SystemRoot WINDIR COMSPEC
          SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
          HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
          http_proxy https_proxy all_proxy no_proxy
        ].freeze
        MACOS_CANDIDATES = [
          File.join(Dir.home, ".local", "bin", "codex"),
          "/Applications/ChatGPT.app/Contents/Resources/codex",
          "/Applications/Codex.app/Contents/Resources/codex"
        ].freeze

        Result = Struct.new(
          :available, :argv, :env, :cwd, :source, :version,
          :error_code, :message, keyword_init: true
        ) do
          def available?
            available == true
          end
        end

        def initialize(codex_home:, codex_path: nil, explicit_path: nil,
                       path: nil, base_env: nil, version_probe: nil,
                       app_server_probe: nil, known_candidates: nil,
                       platform: RUBY_PLATFORM, **_unused)
          @codex_home = File.expand_path(codex_home)
          @explicit_path = presence(codex_path) || presence(explicit_path)
          @platform = platform.to_s
          @base_env = stringify_env(base_env || ENV.to_h)
          @path = path.nil? ? @base_env[windows? ? "Path" : "PATH"].to_s : path.to_s
          @version_probe = version_probe || method(:probe_version)
          @app_server_probe = app_server_probe || method(:probe_app_server)
          @known_candidates = known_candidates || MACOS_CANDIDATES
        end

        def resolve
          return failure("unsupported_platform", "Codex CLI is not supported on this platform.") if windows?

          executable, source = resolve_executable
          unless executable
            return failure(
              "codex_cli_missing",
              "Codex CLI is not installed. Install it here, then sign in with ChatGPT."
            )
          end

          version = extract_version(@version_probe.call(executable))
          return failure("invalid_codex_cli", "The detected Codex executable did not report a valid version.") unless version
          unless @app_server_probe.call(executable)
            return failure(
              "codex_cli_too_old",
              "Update Codex CLI to a version that includes App Server."
            )
          end

          Result.new(
            available: true,
            argv: [executable, "app-server", "--stdio"],
            env: sanitized_environment,
            cwd: nil,
            source: source,
            version: version
          )
        rescue StandardError
          failure("codex_cli_probe_failed", "OpenClacky could not inspect the Codex CLI installation.")
        end

        private def resolve_executable
          if @explicit_path
            executable = verified_executable(@explicit_path)
            return [executable, :configured] if executable
            return [nil, nil]
          end

          from_path = find_executable("codex")
          return [from_path, :path] if from_path

          @known_candidates.each do |candidate|
            executable = verified_executable(candidate)
            return [executable, :application] if executable
          end
          [nil, nil]
        end

        private def verified_executable(value)
          candidate = File.expand_path(value.to_s)
          return nil unless File.file?(candidate) && File.executable?(candidate)

          File.realpath(candidate)
        rescue SystemCallError
          nil
        end

        private def find_executable(name)
          @path.split(File::PATH_SEPARATOR).each do |directory|
            next if directory.to_s.empty?

            executable = verified_executable(File.join(directory, name))
            return executable if executable
          end
          nil
        end

        private def probe_version(executable)
          stdout, status = Open3.capture2e(
            sanitized_environment,
            [executable, executable],
            "--version",
            unsetenv_others: true
          )
          status.success? ? stdout : nil
        rescue StandardError
          nil
        end

        private def probe_app_server(executable)
          _stdout, status = Open3.capture2e(
            sanitized_environment,
            [executable, executable],
            "app-server",
            "--help",
            unsetenv_others: true
          )
          status.success?
        rescue StandardError
          false
        end

        private def extract_version(output)
          match = output.to_s.match(/(?:codex(?:-cli)?\s+)?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)/i)
          match && match[1]
        end

        private def sanitized_environment
          allowed = SAFE_ENV_KEYS.each_with_object({}) do |key, result|
            value = @base_env[key]
            result[key] = value if value && !value.empty?
          end
          SHELL_ENV_EXCLUDE.each { |key| allowed.delete(key) }
          allowed["CODEX_HOME"] = @codex_home
          allowed
        end

        private def failure(error_code, message)
          Result.new(
            available: false, argv: [], env: {}, cwd: nil,
            error_code: error_code, message: message
          )
        end

        private def stringify_env(environment)
          environment.each_with_object({}) do |(key, value), result|
            result[key.to_s] = value.to_s unless value.nil?
          end
        end

        private def presence(value)
          text = value.to_s.strip
          text.empty? ? nil : text
        end

        private def windows?
          @platform.match?(/mswin|mingw|cygwin/i)
        end
      end
    end
  end
end
