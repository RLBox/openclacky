# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::AgentRuntimeRegistry do
  it "builds a registered runtime with keyword options" do
    calls = []
    factory = lambda do |**options|
      calls << options
      { "built" => true, "options" => options }
    end
    registry = described_class.new(factories: { codex: factory })

    expect(registry.registered?("codex")).to be(true)
    expect(registry.build(:codex, session_id: "session-1")).to eq(
      "built" => true,
      "options" => { session_id: "session-1" }
    )
    expect(calls).to eq([{ session_id: "session-1" }])
  end

  it "raises a dedicated error for an unknown runtime" do
    registry = described_class.new(factories: {})

    expect(registry.registered?("missing")).to be(false)
    expect { registry.build("missing") }.to raise_error(
      Clacky::AgentRuntimeRegistry::UnknownRuntimeError,
      /unknown agent runtime id: missing/
    )
  end

  it "rejects invalid factories at registration" do
    expect do
      described_class.new(factories: { "invalid" => Object.new })
    end.to raise_error(
      Clacky::AgentRuntimeRegistry::InvalidFactoryError,
      /invalid factory/
    )
  end

  it "shuts down only factories used during this server run" do
    used = Class.new do
      class << self
        attr_accessor :shutdown_calls

        def shutdown
          self.shutdown_calls = shutdown_calls.to_i + 1
        end
      end

      def initialize(**_options); end
    end
    unused = Class.new(used)
    used.shutdown_calls = 0
    unused.shutdown_calls = 0
    registry = described_class.new(factories: { used: used, unused: unused })
    registry.build("used")

    registry.shutdown

    expect(used.shutdown_calls).to eq(1)
    expect(unused.shutdown_calls).to eq(0)
  end
end
