# frozen_string_literal: true

module Clacky
  module DefaultExtensions
    module Codex
      # The only host-facing registration surface for the bundled provider.
      module Registration
        module RuntimeFactory
          module_function

          def new(**options)
            require File.expand_path("runtime.rb", __dir__)
            Clacky::DefaultExtensions::Codex::Runtime.new(**options)
          end

          def shutdown
            return unless defined?(Clacky::DefaultExtensions::Codex::Runtime)

            Clacky::DefaultExtensions::Codex::Runtime.shutdown
          end
        end

        module_function

        def provider
          {
            "name" => "ChatGPT",
            "name_key" => "provider.name.codex",
            "runtime_id" => "codex",
            "extension_id" => "codex",
            "auth_mode" => "runtime",
            "credential_fields" => [],
            "dynamic_models" => "discovery",
            "capabilities" => {
              "chat" => true,
              "tools" => true,
              "vision" => true
            },
            "website_url" => "https://openai.com/codex"
          }
        end

        def runtime_factory
          RuntimeFactory
        end

        def enabled?
          result = Clacky::ExtensionLoader.last_result
          container = result.containers["codex"]
          !!(container && !container[:disabled])
        rescue StandardError
          false
        end
      end
    end
  end
end
