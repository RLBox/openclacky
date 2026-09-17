# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ProviderRegistry do
  it "combines API presets with explicit runtime providers" do
    registry = described_class.new(
      presets: { "legacy" => { name: "Legacy", models: ["legacy-model"] } },
      providers: {
        codex: {
          name: "ChatGPT",
          runtime_id: "codex",
          capabilities: { vision: true }
        }
      }
    )

    expect(registry.all.keys).to eq(%w[legacy codex])
    expect(registry["legacy"]).to eq(
      "name" => "Legacy",
      "models" => ["legacy-model"]
    )
    expect(registry["codex"]).to include(
      "name" => "ChatGPT",
      "runtime_id" => "codex",
      "capabilities" => { vision: true }
    )
  end

  it "returns defensive copies" do
    source = {
      "runtime" => {
        "name" => "Runtime",
        "runtime_id" => "runtime",
        "models" => ["one"]
      }
    }
    registry = described_class.new(presets: {}, providers: source)

    registry.all["runtime"]["models"] << "mutated"
    registry["runtime"]["name"].replace("changed")
    source["runtime"]["models"] << "source-change"

    expect(registry["runtime"]).to eq(
      "name" => "Runtime",
      "runtime_id" => "runtime",
      "models" => ["one"]
    )
  end

  it "resolves runtime ids and distinguishes optional from required lookup" do
    registry = described_class.new(
      presets: {},
      providers: { "runtime" => { "runtime_id" => "adapter" } }
    )

    expect(registry.runtime_id_for(:runtime)).to eq("adapter")
    expect(registry["missing"]).to be_nil
    expect { registry.fetch("missing") }.to raise_error(
      Clacky::ProviderRegistry::UnknownProviderError,
      /unknown provider id: missing/
    )
  end

  it "rejects duplicate provider ids after normalization" do
    expect do
      described_class.new(
        presets: { "codex" => { "name" => "first" } },
        providers: { codex: { "name" => "second" } }
      )
    end.to raise_error(ArgumentError, /duplicate provider id: codex/)
  end
end
