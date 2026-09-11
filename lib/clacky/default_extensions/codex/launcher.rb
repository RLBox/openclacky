# frozen_string_literal: true

require "open3"
require "json"

module Clacky
  module DefaultExtensions
    module Codex
      # Resolves a pinned codex-acp launch command without invoking a shell.
      class Launcher
        ADAPTER_VERSION = "1.11.0"
        ADAPTER_NAME = "@agentclientprotocol/codex-acp"
        ADAPTER_PACKAGE = "#{ADAPTER_NAME}@#{ADAPTER_VERSION}"
        MIN_NODE_MAJOR = 20
        PACKAGED_ROOT = File.join(__dir__, "vendor")
        ADAPTER_CONTROL_ENV_KEYS = %w[
          APP_SERVER_LOGS
          DEFAULT_AUTH_REQUEST
          DISABLE_MCP_CONFIG_FILTERING
          MODEL_PROVIDER
        ].freeze

        Result = Struct.new(
          :available,
          :argv,
          :env,
          :source,
          :version,
          :error_code,
          :message,
          keyword_init: true
        ) do
          def available?
            available == true
          end
        end

        def initialize(codex_home:, explicit_path: nil, codex_path: nil,
                       packaged_node: nil, packaged_entrypoint: nil,
                       path: nil, base_env: nil, version_probe: nil,
                       platform: RUBY_PLATFORM)
          @codex_home = File.expand_path(codex_home)
          @explicit_path = presence(explicit_path)
          @codex_path = presence(codex_path)
          @platform = platform.to_s
          @base_env = stringify_env(base_env || ENV.to_h)
          @path = path.nil? ? @base_env["PATH"].to_s : path.to_s
          @packaged_node = File.expand_path(packaged_node || default_packaged_node)
          @packaged_entrypoint = File.expand_path(
            packaged_entrypoint || File.join(
              PACKAGED_ROOT,
              "node_modules",
              "@agentclientprotocol",
              "codex-acp",
              "dist",
              "index.js"
            )
          )
          @version_probe = version_probe
        end

        def resolve
          codex_override, codex_error = verified_codex_override
          return failure("invalid_codex_path", codex_error) if codex_error

          if @explicit_path
            explicit = verified_executable(@explicit_path)
            unless explicit
              return failure(
                "invalid_explicit_path",
                "Configured codex-acp path must be an executable file."
              )
            end
            return success([explicit], :explicit, nil, codex_override)
          end

          if executable_file?(@packaged_node) && File.file?(@packaged_entrypoint)
            return success(
              [@packaged_node, @packaged_entrypoint],
              :packaged,
              ADAPTER_VERSION,
              codex_override
            )
          end

          installed = find_executable("codex-acp")
          installed_version = installed && installed_adapter_version(installed)
          if installed && installed_version == ADAPTER_VERSION
            return success([installed], :installed, installed_version, codex_override)
          end

          node = find_executable("node")
          npx = find_executable("npx")
          if node && npx
            detected_node_version = node_version(node)
            node_major = detected_node_version.to_s.split(".").first.to_i
            if detected_node_version.nil? || node_major < MIN_NODE_MAJOR
              return failure(
                "incompatible_node",
                "Pinned npx fallback requires Node.js 20 or newer."
              )
            end
            return success(
              [npx, "-y", ADAPTER_PACKAGE],
              :npx,
              ADAPTER_VERSION,
              codex_override
            )
          end

          if installed
            found = installed_version || "unknown"
            return failure(
              "incompatible_codex_acp",
              "Installed codex-acp version #{found} is incompatible; version #{ADAPTER_VERSION} is required."
            )
          end

          failure(
            "missing_dependencies",
            "Install codex-acp #{ADAPTER_VERSION}, or install Node.js 20+ with npx for the pinned fallback."
          )
        end

        private def default_packaged_node
          if windows?
            File.join(PACKAGED_ROOT, "node", "node.exe")
          else
            File.join(PACKAGED_ROOT, "node", "bin", "node")
          end
        end

        private def verified_codex_override
          return [find_executable("codex"), nil] unless @codex_path

          verified = verified_executable(@codex_path)
          return [verified, nil] if verified

          [nil, "Configured CODEX_PATH must be an executable file."]
        end

        private def verified_executable(path)
          expanded = File.expand_path(path)
          executable_file?(expanded) ? expanded : nil
        end

        private def executable_file?(path)
          File.file?(path) && File.executable?(path)
        end

        private def find_executable(name)
          executable_names(name).each do |candidate_name|
            @path.split(File::PATH_SEPARATOR).each do |directory|
              next if directory.to_s.empty?

              candidate = File.expand_path(File.join(directory, candidate_name))
              return candidate if executable_file?(candidate)
            end
          end
          nil
        end

        private def executable_names(name)
          return [name] unless windows?

          extensions = @base_env.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";")
          [name] + extensions.map { |extension| "#{name}#{extension.downcase}" }
        end

        private def installed_adapter_version(path)
          return extract_version(safe_probe(path)) if @version_probe

          package_metadata_version(path)
        end

        private def node_version(path)
          output = @version_probe ? safe_probe(path) : probe_command_version(path)
          extract_version(output)
        end

        private def safe_probe(path)
          @version_probe && @version_probe.call(path)
        rescue StandardError
          nil
        end

        private def probe_command_version(path)
          stdout, _stderr, status = Open3.capture3(sanitized_environment(nil), path, "--version")
          status.success? ? stdout.to_s : nil
        rescue SystemCallError
          nil
        end

        private def package_metadata_version(executable)
          directory = File.dirname(File.realpath(executable))
          8.times do
            package_file = File.join(directory, "package.json")
            if File.file?(package_file)
              metadata = JSON.parse(File.read(package_file))
              if metadata["name"] == ADAPTER_NAME
                return extract_version(metadata["version"])
              end
            end

            parent = File.dirname(directory)
            break if parent == directory

            directory = parent
          end
          nil
        rescue JSON::ParserError, SystemCallError
          nil
        end

        private def extract_version(output)
          match = output.to_s.match(/(?:^|[^\d])(\d+\.\d+\.\d+)(?![\d.+-])/)
          match && match[1]
        end

        private def success(argv, source, version, codex_override)
          Result.new(
            available: true,
            argv: argv,
            env: sanitized_environment(codex_override),
            source: source,
            version: version
          )
        end

        private def failure(error_code, message)
          Result.new(
            available: false,
            env: sanitized_environment(nil),
            error_code: error_code,
            message: message
          )
        end

        private def sanitized_environment(codex_override)
          env = @base_env.dup
          env.each_key do |key|
            env[key] = nil if key.start_with?("OPENAI_", "CODEX_")
          end
          ADAPTER_CONTROL_ENV_KEYS.each { |key| env[key] = nil }
          env["CODEX_HOME"] = @codex_home
          env["INITIAL_AGENT_MODE"] = "read-only"
          env["CODEX_PATH"] = codex_override if codex_override
          env
        end

        private def stringify_env(env)
          env.each_with_object({}) do |(key, value), result|
            result[key.to_s] = value.to_s
          end
        end

        private def presence(value)
          string = value.to_s.strip
          string.empty? ? nil : string
        end

        private def windows?
          @platform.match?(/mswin|mingw|cygwin/i)
        end
      end
    end
  end
end
