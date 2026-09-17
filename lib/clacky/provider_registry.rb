# frozen_string_literal: true

require_relative "default_extensions/codex/registration"

module Clacky
  # Read-only provider metadata used by configuration and onboarding APIs.
  class ProviderRegistry
    class UnknownProviderError < StandardError; end

    def initialize(presets: Providers::PRESETS, providers: nil)
      @providers = {}
      presets.each { |id, descriptor| add(id, descriptor) }

      additions = providers.nil? ? default_runtime_providers : providers
      additions.each { |id, descriptor| add(id, descriptor) }
    end

    def all
      deep_copy(@providers)
    end

    def [](provider_id)
      descriptor = @providers[provider_id.to_s]
      descriptor && deep_copy(descriptor)
    end

    def fetch(provider_id)
      self[provider_id] || raise(
        UnknownProviderError,
        "unknown provider id: #{provider_id}"
      )
    end

    def runtime_id_for(provider_id)
      descriptor = @providers[provider_id.to_s]
      runtime_id = descriptor && descriptor["runtime_id"]
      runtime_id && deep_copy(runtime_id)
    end

    private def add(id, descriptor)
      provider_id = id.to_s
      raise ArgumentError, "provider id cannot be empty" if provider_id.empty?
      raise ArgumentError, "duplicate provider id: #{provider_id}" if @providers.key?(provider_id)
      raise ArgumentError, "provider descriptor must be a hash" unless descriptor.is_a?(Hash)

      @providers[provider_id] = deep_copy(descriptor).transform_keys(&:to_s)
    end

    private def default_runtime_providers
      registration = Clacky::DefaultExtensions::Codex::Registration
      registration.enabled? ? { "codex" => registration.provider } : {}
    end

    private def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[deep_copy(key)] = deep_copy(item)
        end
      when Array
        value.map { |item| deep_copy(item) }
      else
        value.dup
      end
    rescue TypeError
      value
    end
  end
end
