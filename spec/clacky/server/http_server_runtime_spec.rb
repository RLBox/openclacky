# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"
require "clacky/runtime_session"
require "clacky/agent_runtime_registry"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "runtime session lifecycle" do
  include HttpServerSpecHelpers

  RuntimeServerSpecProfile = Struct.new(:name) do
    def container_dir
      nil
    end
  end

  class RuntimeServerSpecAdapter
    attr_reader :context, :persisted_state, :runs, :cancel_reasons

    def initialize(context:, persisted_state: nil)
      @context = context
      @persisted_state = persisted_state
      @runs = []
      @cancel_reasons = []
      @closed = false
    end

    def capabilities
      { cancel: true }
    end

    def run(input, generation:)
      @runs << [input, generation]
      @context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "assistant-1",
        content: "Runtime reply"
      )
      { stop_reason: "end_turn" }
    end

    def cancel(reason:)
      @cancel_reasons << reason
      true
    end

    def dump_state
      @persisted_state || {
        "session_id" => "external-new",
        "model" => "codex-current"
      }
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  class BarrierRuntimeServerSpecAdapter < RuntimeServerSpecAdapter
    attr_reader :timeline

    def initialize(**options)
      super
      @timeline = []
      @first_started = Queue.new
      @first_response = Queue.new
    end

    def run(input, generation:)
      @runs << [input, generation]
      @timeline << [:started, input.content]
      if @runs.length == 1
        @first_started << true
        @first_response.pop
        @timeline << [:completed, input.content]
      end
      { stop_reason: "end_turn" }
    end

    def cancel(reason:)
      @cancel_reasons << reason
      @timeline << [:cancelled, reason]
      true
    end

    def wait_until_first_started
      @first_started.pop
    end

    def complete_first_prompt
      @first_response << true
    end
  end

  let(:runtime_config) do
    Clacky::AgentConfig.new(models: [
      {
        "id" => "runtime-card-current",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default"
      }
    ])
  end
  let(:built_runtimes) { [] }
  let(:runtime_factory) do
    lambda do |**options|
      RuntimeServerSpecAdapter.new(**options).tap { |runtime| built_runtimes << runtime }
    end
  end
  let(:runtime_registry) do
    Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: { "codex" => runtime_factory }
    )
  end
  let(:provider_registry) do
    Clacky::ProviderRegistry.new(
      extension_units: [],
      presets: {
        "codex" => {
          "id" => "codex",
          "name" => "Codex",
          "runtime_id" => "codex",
          "auth_mode" => "runtime"
        }
      }
    )
  end

  before do
    allow(Clacky::AgentProfile).to receive(:load)
      .and_return(RuntimeServerSpecProfile.new("general"))
  end

  def persisted_runtime_session(session_id: "runtime-restored", provider_id: "codex")
    {
      session_id: session_id,
      name: "Restored runtime",
      pinned: false,
      created_at: "2026-09-10T00:00:00Z",
      updated_at: "2026-09-10T00:00:01Z",
      working_dir: Dir.pwd,
      source: "manual",
      agent_profile: "general",
      config: {
        permission_mode: "confirm_all",
        model_id: "runtime-card-from-an-old-process",
        provider_id: provider_id
      },
      runtime: {
        id: "codex",
        version: 1,
        state: {
          "session_id" => "external-restored",
          "model" => "codex-restored"
        }
      },
      stats: { total_tasks: 1, total_cost_usd: 0.0, cost_source: "provider" },
      messages: [
        { role: "user", content: "Earlier question", created_at: 1.0 },
        { role: "assistant", content: "Earlier answer", created_at: 2.0 }
      ]
    }
  end

  it "selects the runtime before constructing an API client" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Codex task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      session = server.instance_variable_get(:@registry).get(session_id)
      agent = session[:agent]

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(session[:idle_timer]).to be_nil
      expect(built_runtimes.fetch(0).context).to include(
        session_id: session_id,
        working_dir: Dir.pwd
      )
      expect(server.instance_variable_get(:@session_manager).load(session_id))
        .to include(runtime: hash_including(id: "codex"))
    end
  end

  it "restores by stable runtime and provider identity without provider-history replay" do
    config = Clacky::AgentConfig.new(models: [
      {
        "id" => "other-provider-card",
        "provider_id" => "other",
        "runtime_id" => "codex",
        "display_model" => "Other runtime",
        "type" => "default"
      },
      {
        "id" => "runtime-card-regenerated",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default"
      }
    ])
    client_factory = lambda { raise "API client must not be built" }

    with_server(
      agent_config: config,
      client_factory: client_factory,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      data = persisted_runtime_session
      session_id = server.send(:build_session_from_data, data)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(agent.current_model_info).to include(
        id: "runtime-card-regenerated",
        provider_id: "codex",
        runtime_id: "codex"
      )
      expect(built_runtimes.fetch(0).persisted_state).to eq(data[:runtime][:state])
      expect(built_runtimes.fetch(0).runs).to be_empty

      req = fake_req(method: "GET", path: "/api/sessions/#{session_id}/messages")
      res = fake_res
      server.send(:api_session_messages, session_id, req, res)

      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
      expect(built_runtimes.fetch(0).runs).to be_empty
    end
  end

  it "keeps a restored transcript readable when its runtime is unavailable" do
    unavailable_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: {}
    )
    client_factory = lambda { raise "API client must not be built" }

    with_server(
      agent_config: runtime_config,
      client_factory: client_factory,
      provider_registry: provider_registry,
      runtime_registry: unavailable_registry
    ) do |server|
      session_id = server.send(:build_session_from_data, persisted_runtime_session)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      req = fake_req(method: "GET", path: "/api/sessions/#{session_id}/messages")
      res = fake_res

      server.send(:api_session_messages, session_id, req, res)

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
      expect(agent.to_session_data[:runtime][:state]).to include(
        "session_id" => "external-restored"
      )
    end
  end

  it "keeps a restored transcript readable when the registered adapter fails to load" do
    broken_registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [],
      factories: { "codex" => lambda { |**_options| raise LoadError, "broken" } }
    )
    client_factory = lambda { raise "API client must not be built" }

    with_server(
      agent_config: runtime_config,
      client_factory: client_factory,
      provider_registry: provider_registry,
      runtime_registry: broken_registry
    ) do |server|
      data = persisted_runtime_session
      session_id = server.send(:build_session_from_data, data)
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      res = fake_res

      server.send(
        :api_session_messages,
        session_id,
        fake_req(method: "GET", path: ""),
        res
      )

      expect(agent).to be_a(Clacky::RuntimeSession)
      expect(res.status).to eq(200)
      expect(parsed_body(res)["events"].map { |event| event["content"] })
        .to eq(["Earlier question", "Earlier answer"])
      expect(agent.to_session_data[:runtime][:state])
        .to include("session_id" => "external-restored")
    end
  end

  it "uses the existing supervisor as the runtime generation and persistence boundary" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      registry = server.instance_variable_get(:@registry)
      agent = registry.get(session_id)[:agent]
      allow(registry).to receive(:evict_excess_idle!)

      worker = server.send(:run_agent_task, session_id, agent) { agent.run("Hello") }

      expect(worker.join(2)).not_to be_nil
      expect(built_runtimes.fetch(0).runs.fetch(0).last).to eq(1)
      expect(registry.get(session_id)).to include(status: :idle, idle_timer: nil)
      saved = server.instance_variable_get(:@session_manager).load(session_id)
      expect(saved.dig(:stats, :last_status)).to eq("success")
      expect(saved.dig(:runtime, :id)).to eq("codex")
    end
  end

  it "cancels a running ACP turn and drains its replacement only after the prompt response" do
    barrier_runtimes = []
    barrier_factory = lambda do |**options|
      BarrierRuntimeServerSpecAdapter.new(**options).tap do |runtime|
        barrier_runtimes << runtime
      end
    end
    registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [], factories: { "codex" => barrier_factory }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      runtime = barrier_runtimes.fetch(0)
      worker = server.send(:run_agent_task, session_id, agent) { agent.run("first") }
      runtime.wait_until_first_started

      server.send(:handle_user_message, session_id, "second")

      expect(runtime.cancel_reasons).to eq([:replacement])
      expect(runtime.runs.map { |input, _generation| input.content }).to eq(["first"])
      expect(worker).to be_alive

      runtime.complete_first_prompt
      expect(worker.join(2)).not_to be_nil
      expect(runtime.runs.map { |input, _generation| input.content })
        .to eq(["first", "second"])
      expect(runtime.timeline).to eq([
        [:started, "first"],
        [:cancelled, :replacement],
        [:completed, "first"],
        [:started, "second"]
      ])
    ensure
      runtime&.complete_first_prompt if worker&.alive?
      worker&.join(1)
    end
  end

  it "keeps an explicitly cancelled runtime worker alive until the ACP response barrier" do
    barrier_runtimes = []
    barrier_factory = lambda do |**options|
      BarrierRuntimeServerSpecAdapter.new(**options).tap do |runtime|
        barrier_runtimes << runtime
      end
    end
    registry = Clacky::AgentRuntimeRegistry.new(
      extension_units: [], factories: { "codex" => barrier_factory }
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      runtime = barrier_runtimes.fetch(0)
      worker = server.send(:run_agent_task, session_id, agent) { agent.run("first") }
      runtime.wait_until_first_started

      server.send(:interrupt_session, session_id, reason: :user)

      expect(runtime.cancel_reasons).to eq([:user])
      expect(worker).to be_alive
      runtime.complete_first_prompt
      expect(worker.join(2)).not_to be_nil
      expect(server.instance_variable_get(:@registry).get(session_id)[:status])
        .to eq(:idle)
      expect(server.instance_variable_get(:@session_manager).load(session_id)
        .dig(:stats, :last_status)).to eq("interrupted")
    ensure
      runtime&.complete_first_prompt if worker&.alive?
      worker&.join(1)
    end
  end

  it "rejects fork instead of copying an external runtime session id" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      res = fake_res

      server.send(:api_fork_session, session_id, fake_req(method: "POST", path: ""), res)

      expect(res.status).to eq(409)
      expect(parsed_body(res)["error"]).to match(/runtime/i)
      expect(server.instance_variable_get(:@session_manager).all_sessions.length).to eq(1)
    end
  end

  it "returns explicit capability errors for agent-only session APIs" do
    runtime_config.models << {
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    }

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )

      checks = [
        [:api_session_skills, [session_id]],
        [:api_session_time_machine, [session_id]],
        [:api_session_messages, [session_id, fake_req(
          method: "GET", path: "", query_string: "navigation=1"
        )]],
        [:api_switch_session_model, [session_id, fake_req(
          method: "PATCH", path: "", body: { model_id: "api-card" }
        )]],
        [:api_change_session_working_dir, [session_id, fake_req(
          method: "PATCH", path: "", body: { working_dir: Dir.pwd }
        )]]
      ]

      checks.each do |method_name, arguments|
        res = fake_res
        server.send(method_name, *arguments, res)
        expect(res.status).to eq(409), method_name.to_s
        expect(parsed_body(res)["error"]).to match(/not support|unavailable/i)
      end
    end
  end

  it "rejects switching an API session onto a runtime provider card" do
    runtime_config.models.unshift(
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "API task",
        working_dir: Dir.pwd,
        model_id: "api-card"
      )
      agent = server.instance_variable_get(:@registry).get(session_id)[:agent]
      res = fake_res

      server.send(
        :api_switch_session_model,
        session_id,
        fake_req(method: "PATCH", path: "", body: { model_id: "runtime-card-current" }),
        res
      )

      expect(res.status).to eq(409)
      expect(parsed_body(res)["error"]).to match(/new session|runtime/i)
      expect(agent.current_model_info[:id]).to eq("api-card")
    end
  end

  it "excludes runtime provider cards from API model benchmarks" do
    runtime_config.models.unshift(
      "id" => "api-card",
      "provider_id" => "custom",
      "model" => "api-model",
      "base_url" => "https://example.test",
      "api_key" => "secret"
    )

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "API task",
        working_dir: Dir.pwd,
        model_id: "api-card"
      )
      allow(server).to receive(:benchmark_single_model) do |entry, _timeout|
        { model_id: entry["id"], model: entry["model"], ok: true }
      end
      res = fake_res

      server.send(
        :api_benchmark_session_models,
        session_id,
        fake_req(method: "POST", path: ""),
        res
      )

      expect(res.status).to eq(200)
      expect(parsed_body(res)["results"].map { |row| row["model_id"] }).to eq(["api-card"])
    end
  end

  it "closes the runtime when its live session is deleted" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      session_id = server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)
      res = fake_res

      server.send(:api_delete_session, session_id, res)

      expect(res.status).to eq(200)
      expect(runtime.closed?).to be(true)
    end
  end

  it "closes idle runtime sessions during server shutdown" do
    expect(Clacky::Client).not_to receive(:new)

    with_server(
      agent_config: runtime_config,
      provider_registry: provider_registry,
      runtime_registry: runtime_registry
    ) do |server|
      server.send(
        :build_session,
        name: "Runtime task",
        working_dir: Dir.pwd,
        model_id: "runtime-card-current"
      )
      runtime = built_runtimes.fetch(0)

      server.send(:interrupt_all_agents)

      expect(runtime.closed?).to be(true)
    end
  end
end
