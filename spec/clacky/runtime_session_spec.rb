# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::RuntimeSession do
  FakeProfile = Struct.new(:name)

  class RuntimeSessionSpecUI
    attr_reader :assistant_messages, :tool_calls, :tool_results, :queues, :events

    def initialize
      @assistant_messages = []
      @tool_calls = []
      @tool_results = []
      @queues = []
      @events = []
    end

    def show_assistant_message(content, files:, interim: false, created_at: nil)
      @assistant_messages << { content: content, files: files, interim: interim, created_at: created_at }
    end

    def show_tool_call(name, args)
      @tool_calls << [name, args]
    end

    def show_tool_result(result)
      @tool_results << result
    end

    def show_input_queue(entries)
      @queues << entries
    end

    def show_user_message(*); end

    def emit(type, **data)
      @events << [type, data]
    end
  end

  class RuntimeSessionSpecRuntime
    attr_reader :context, :persisted_state, :inputs, :cancel_reasons

    def initialize(context:, persisted_state: nil)
      @context = context
      @persisted_state = persisted_state
      @inputs = []
      @cancel_reasons = []
      @closed = false
    end

    def capabilities
      { cancel: true, image_input: true }
    end

    def run(input, generation:)
      @inputs << [input, generation]
      @context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "assistant-1",
        content: "Hello "
      )
      @context[:event_sink].call(
        generation,
        type: :tool_call,
        tool_call_id: "tool-1",
        name: "terminal",
        input: { "command" => "pwd" }
      )
      @context[:event_sink].call(
        generation,
        type: :tool_result,
        tool_call_id: "tool-1",
        result: "/workspace"
      )
      @context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "assistant-1",
        content: "world"
      )
      { stop_reason: "end_turn" }
    end

    def cancel(reason:)
      @cancel_reasons << reason
      true
    end

    def dump_state
      {
        "session_id" => "acp-session-1",
        "model" => "gpt-5.3-codex",
        "reasoning_effort" => "high"
      }
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  let(:ui) { RuntimeSessionSpecUI.new }
  let(:config) do
    Clacky::AgentConfig.new(models: [
      {
        "id" => "runtime-card-1",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default"
      }
    ], permission_mode: :confirm_all)
  end
  let(:built_runtimes) { [] }
  let(:runtime_factory) do
    lambda do |context:, persisted_state: nil|
      runtime = RuntimeSessionSpecRuntime.new(
        context: context,
        persisted_state: persisted_state
      )
      built_runtimes << runtime
      runtime
    end
  end

  def build_session(**overrides)
    described_class.new(
      runtime_id: "codex",
      runtime_factory: runtime_factory,
      config: config,
      working_dir: "/workspace",
      ui: ui,
      profile: FakeProfile.new("general"),
      session_id: "session-1",
      source: :manual,
      **overrides
    )
  end

  it "builds the provider runtime with a host context" do
    session = build_session
    runtime = built_runtimes.fetch(0)

    expect(runtime.context).to include(
      session_id: "session-1",
      working_dir: "/workspace",
      permission_mode: "confirm_all",
      ui: ui
    )
    expect(runtime.context[:event_sink]).to respond_to(:call)
    expect(runtime.persisted_state).to be_nil
    expect(session.runtime?).to be(true)
    expect(session.capability?(:cancel)).to be(true)
    expect(session.capability?(:time_machine)).to be(false)
  ensure
    session&.close
  end

  it "runs one turn, mirrors history, and finalizes streamed assistant text" do
    session = build_session

    Thread.current[:task_epoch] = 7
    result = session.run(
      "Say hello",
      files: [{ "name" => "photo.png", "data_url" => "data:image/png;base64,AA==" }],
      reference_contexts: ["Reference context"],
      created_at: 123.5,
      references_display: [{ "type" => "session", "session_id" => "other" }]
    )

    runtime_input, generation = built_runtimes.fetch(0).inputs.fetch(0)
    expect(generation).to eq(7)
    expect(runtime_input.content).to eq("Say hello")
    expect(runtime_input.files.first["name"]).to eq("photo.png")
    expect(runtime_input.reference_contexts).to eq(["Reference context"])
    expect(result).to include(stop_reason: "end_turn", awaiting_user_feedback: false)
    expect(session.history.to_a.map { |message| message[:role] }).to eq(%w[user assistant])
    expect(session.history.to_a.last[:content]).to eq("Hello world")
    expect(ui.assistant_messages.last[:content]).to eq("Hello world")
    expect(ui.tool_calls).to eq([["terminal", { "command" => "pwd" }]])
    expect(ui.tool_results).to eq(["/workspace"])
    expect(session.total_tasks).to eq(1)
  ensure
    Thread.current[:task_epoch] = nil
    session&.close
  end

  it "drops provider events from a stale generation" do
    session = build_session
    session.begin_generation(4)

    accepted = session.accept_runtime_event(
      3,
      type: :assistant_delta,
      message_id: "late",
      content: "must not appear"
    )

    expect(accepted).to be(false)
    expect(session.history).to be_empty
    expect(ui.assistant_messages).to be_empty
  ensure
    session&.close
  end

  it "owns editable FIFO pending input independently of the provider" do
    session = build_session
    first_id = session.enqueue_input("first", files: [])
    second_id = session.enqueue_input("second", display_text: "Second")

    expect(session.edit_pending_input(second_id, "updated")).to be(true)
    expect(session.remove_pending_input("missing")).to be_nil
    expect(session.take_pending_input).to include(id: first_id, content: "first")
    expect(session.remove_pending_input(second_id)).to include(content: "updated")
    expect(session.pending_inputs).to be_empty
    expect(ui.queues).not_to be_empty
  ensure
    session&.close
  end

  it "serializes runtime identity and resume state without API credentials" do
    session = build_session
    session.rename("Codex work")
    session.pinned = true
    session.project_id = "project-1"

    data = session.to_session_data(status: :success, updated_at: Time.at(200))

    expect(data).to include(
      session_id: "session-1",
      name: "Codex work",
      pinned: true,
      working_dir: "/workspace",
      source: "manual",
      project_id: "project-1"
    )
    expect(data[:runtime]).to eq(
      id: "codex",
      version: 1,
      state: {
        "session_id" => "acp-session-1",
        "model" => "gpt-5.3-codex",
        "reasoning_effort" => "high"
      }
    )
    expect(data[:config]).to include(
      permission_mode: "confirm_all",
      model_id: "runtime-card-1",
      provider_id: "codex"
    )
    serialized = JSON.generate(data)
    expect(serialized).not_to include("api_key", "access_token", "refresh_token")
  ensure
    session&.close
  end

  it "restores the local transcript and passes only provider state to the runtime" do
    data = {
      session_id: "restored-session",
      name: "Restored",
      pinned: true,
      working_dir: "/restored",
      created_at: "2026-09-10T00:00:00Z",
      source: "manual",
      project_id: "project-2",
      pending_inputs: [{ id: "queued-1", content: "later", options: {} }],
      stats: { total_tasks: 3, total_cost_usd: 0.0, cost_source: "provider" },
      messages: [{ role: "user", content: "Earlier", created_at: 1.0 }],
      runtime: {
        id: "codex",
        version: 1,
        state: { session_id: "external-session", model: "gpt-5.3-codex" }
      }
    }

    session = described_class.from_session(
      runtime_factory: runtime_factory,
      config: config,
      session_data: data,
      ui: ui,
      profile: FakeProfile.new("general")
    )

    expect(session.session_id).to eq("restored-session")
    expect(session.name).to eq("Restored")
    expect(session.history.to_a.first[:content]).to eq("Earlier")
    expect(session.pending_inputs.first[:content]).to eq("later")
    expect(session.total_tasks).to eq(3)
    expect(built_runtimes.fetch(0).persisted_state).to eq(
      session_id: "external-session",
      model: "gpt-5.3-codex"
    )
  ensure
    session&.close
  end

  it "delegates cooperative cancellation and rejects agent-only operations" do
    session = build_session

    expect(session.cancel(reason: :replacement)).to be(true)
    expect(built_runtimes.fetch(0).cancel_reasons).to eq([:replacement])
    expect(session.parse_skill_command("/onboard")).to eq(found: false)
    expect { session.change_working_dir("/elsewhere") }.to raise_error(
      Clacky::RuntimeSession::UnsupportedCapability,
      /working directory/
    )
    expect { session.fork_runtime_state }.to raise_error(
      Clacky::RuntimeSession::UnsupportedCapability,
      /fork/
    )
  ensure
    session&.close
  end

  it "replays its normalized local transcript without consulting the provider" do
    session = build_session
    session.history.append(role: "user", content: "Question", created_at: 1.0)
    session.history.append(role: "assistant", content: "Answer", created_at: 2.0)
    replay_ui = RuntimeSessionSpecUI.new

    result = session.replay_history(replay_ui, limit: 20)

    expect(result).to eq(has_more: false)
    expect(replay_ui.assistant_messages.last[:content]).to eq("Answer")
  ensure
    session&.close
  end
end
