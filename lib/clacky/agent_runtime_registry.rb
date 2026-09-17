# frozen_string_literal: true

require_relative "default_extensions/codex/registration"

module Clacky
  # Small process-lifetime boundary for runtime construction and shutdown.
  class AgentRuntimeRegistry
    class UnknownRuntimeError < StandardError; end
    class InvalidFactoryError < StandardError; end

    def initialize(factories: nil)
      @factories = normalize_factories(
        factories.nil? ? default_factories : factories
      )
      @resolved = {}
      @lock = Mutex.new
    end

    def registered?(runtime_id)
      @factories.key?(runtime_id.to_s)
    end

    def build(runtime_id, **kwargs)
      id = runtime_id.to_s
      factory = @factories[id]
      raise UnknownRuntimeError, "unknown agent runtime id: #{id}" unless factory

      @lock.synchronize { @resolved[id] = factory }
      if factory.is_a?(Class) || factory.respond_to?(:new)
        factory.new(**kwargs)
      elsif factory.respond_to?(:call)
        factory.call(**kwargs)
      else
        raise InvalidFactoryError, "invalid factory for agent runtime #{id}"
      end
    end

    def shutdown
      @lock.synchronize { @resolved.values.uniq }.each do |factory|
        factory.shutdown if factory.respond_to?(:shutdown)
      rescue StandardError => e
        Clacky::Logger.warn(
          "[AgentRuntimeRegistry] shutdown failed: #{e.class}: #{e.message}"
        ) if defined?(Clacky::Logger)
      end
      nil
    end

    private def default_factories
      registration = Clacky::DefaultExtensions::Codex::Registration
      registration.enabled? ? { "codex" => registration.runtime_factory } : {}
    end

    private def normalize_factories(factories)
      factories.each_with_object({}) do |(runtime_id, factory), normalized|
        id = runtime_id.to_s
        raise ArgumentError, "agent runtime id cannot be empty" if id.empty?
        unless factory.is_a?(Class) || factory.respond_to?(:new) || factory.respond_to?(:call)
          raise InvalidFactoryError, "invalid factory for agent runtime #{id}"
        end

        normalized[id] = factory
      end
    end
  end
end
