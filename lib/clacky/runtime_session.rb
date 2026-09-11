# frozen_string_literal: true

require "securerandom"
require "time"

module Clacky
  # Host-owned session state for an extension-provided agent runtime.
  class RuntimeSession
    class UnsupportedCapability < StandardError; end

    # Keeps the host-owned transcript readable when an extension that owns a
    # persisted runtime session is disabled, missing, or fails to load. It
    # deliberately preserves only the already-sanitized resume state and
    # refuses to execute new turns.
    class UnavailableRuntime
      def initialize(runtime_id:, persisted_state: nil, message: nil)
        @runtime_id = runtime_id.to_s
        @persisted_state = persisted_state.is_a?(Hash) ? persisted_state : {}
        @message = message || "Agent runtime '#{@runtime_id}' is unavailable"
      end

      def capabilities
        {}
      end

      def run(_input, generation:)
        raise UnsupportedCapability, @message
      end

      def dump_state
        deep_copy(@persisted_state)
      end

      def close
        nil
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
          begin
            value.dup
          rescue TypeError
            value
          end
        end
      end
    end

    RuntimeInput = Struct.new(
      :content,
      :files,
      :reference_contexts,
      :display_text,
      :created_at,
      :references_display,
      keyword_init: true
    )

    attr_reader :session_id, :name, :history, :working_dir, :created_at,
      :total_tasks, :total_cost, :cost_source, :ui, :agent_profile, :source,
      :config, :latest_latency, :reasoning_effort, :todos
    attr_accessor :pinned, :project_id, :channel_info

    def self.from_session(runtime_factory:, config:, session_data:, ui:, profile:)
      runtime = value(session_data, :runtime) || {}
      new(
        runtime_id: value(runtime, :id),
        runtime_factory: runtime_factory,
        config: config,
        working_dir: value(session_data, :working_dir) || Dir.pwd,
        ui: ui,
        profile: profile,
        session_id: value(session_data, :session_id),
        source: (value(session_data, :source) || "manual").to_sym,
        persisted_state: value(runtime, :state),
        persisted_data: session_data
      )
    end

    def self.value(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s]
    end

    def initialize(runtime_id:, runtime_factory:, config:, working_dir:, ui:,
                   profile:, session_id:, source:, persisted_state: nil,
                   persisted_data: nil)
      @runtime_id = runtime_id.to_s
      raise ArgumentError, "runtime_id is required" if @runtime_id.empty?

      @config = config
      @working_dir = working_dir || Dir.pwd
      @ui = ui
      @agent_profile = profile
      @session_id = session_id
      @source = source.to_sym
      @name = ""
      @pinned = false
      @project_id = nil
      @channel_info = nil
      @created_at = Time.now.iso8601
      @history = MessageHistory.new
      @input_queue = []
      @input_mutex = Mutex.new
      @total_tasks = 0
      @total_cost = 0.0
      @cost_source = :provider
      @latest_latency = nil
      @reasoning_effort = nil
      @todos = []
      @generation_mutex = Mutex.new
      @current_generation = nil
      @assistant_buffers = {}
      @assistant_order = []
      @closed = false

      restore_host_state(persisted_data) if persisted_data

      context = {
        session_id: @session_id,
        working_dir: @working_dir,
        permission_mode: permission_mode,
        ui: @ui,
        event_sink: method(:accept_runtime_event)
      }
      @runtime = runtime_factory.call(
        context: context,
        persisted_state: deep_copy(persisted_state)
      )
      refresh_effective_configuration
    end

    def runtime?
      true
    end

    def runtime_id
      @runtime_id
    end

    def capabilities
      value = @runtime.respond_to?(:capabilities) ? @runtime.capabilities : {}
      value.is_a?(Hash) ? value : {}
    end

    def capability?(name)
      capabilities[name.to_sym] == true || capabilities[name.to_s] == true
    end

    def permission_mode
      @config&.permission_mode&.to_s || ""
    end

    def reasoning_effort=(value)
      @reasoning_effort = value.to_s.strip
      @reasoning_effort = nil if @reasoning_effort.empty?
    end

    def current_model_info
      card = @config&.current_model || {}
      state = runtime_state
      {
        id: card["id"],
        model: state["model"] || card["display_model"] || "Runtime default",
        base_url: nil,
        provider_id: card["provider_id"],
        runtime_id: @runtime_id,
        remark: card["remark"],
        card_model: card["display_model"],
        sub_model: nil
      }
    end

    def rename(new_name)
      @name = new_name.to_s.strip
    end

    def parse_skill_command(_input)
      { found: false }
    end

    def run(content, files: nil, reference_contexts: nil, display_text: nil,
            created_at: nil, references_display: nil)
      generation = Thread.current[:task_epoch] || next_local_generation
      begin_generation(generation)
      timestamp = created_at || Time.now.to_f
      @history.append(
        role: "user",
        content: content,
        display_text: display_text,
        created_at: timestamp,
        display_files: Array(files),
        display_references: Array(references_display)
      )

      input = RuntimeInput.new(
        content: content,
        files: Array(files),
        reference_contexts: Array(reference_contexts),
        display_text: display_text,
        created_at: timestamp,
        references_display: Array(references_display)
      )
      started_at = Time.now
      result = @runtime.run(input, generation: generation)
      result = {} unless result.is_a?(Hash)
      finalize_assistant_message(generation, result, started_at)
      @total_tasks += 1
      refresh_effective_configuration
      {
        stop_reason: result[:stop_reason] || result["stop_reason"],
        awaiting_user_feedback: !!(
          result[:awaiting_user_feedback] || result["awaiting_user_feedback"]
        )
      }
    end

    def begin_generation(generation)
      @generation_mutex.synchronize do
        @current_generation = generation.to_i
        @assistant_buffers = {}
        @assistant_order = []
      end
      generation
    end

    def accept_runtime_event(generation, event)
      return false unless event.is_a?(Hash)

      current = @generation_mutex.synchronize { @current_generation }
      return false unless current && current.to_i == generation.to_i

      event_type = (event[:type] || event["type"]).to_s
      case event_type
      when "assistant_delta"
        buffer_assistant_delta(event)
      when "tool_call"
        @ui&.show_tool_call(
          event[:name] || event["name"] || "tool",
          event[:input] || event["input"] || {}
        )
      when "tool_result"
        @ui&.show_tool_result(event[:result] || event["result"])
      when "thought"
        @ui&.show_progress(
          event[:content] || event["content"],
          progress_type: "thinking"
        ) if @ui&.respond_to?(:show_progress)
      when "usage"
        apply_usage(event)
      when "plan"
        @todos = Array(event[:entries] || event["entries"])
        @ui&.update_todos(@todos) if @ui&.respond_to?(:update_todos)
      else
        @ui&.emit("runtime_event", runtime_id: @runtime_id, event: event) if @ui&.respond_to?(:emit)
      end
      true
    end

    def enqueue_input(content, **options)
      entry = { id: SecureRandom.uuid, content: content, options: options }
      @input_mutex.synchronize { @input_queue << entry }
      notify_input_queue
      entry[:id]
    end

    def pending_inputs
      @input_mutex.synchronize { deep_copy(@input_queue) }
    end

    def take_pending_input
      @input_mutex.synchronize { @input_queue.shift }
    end

    def edit_pending_input(id, content)
      updated = @input_mutex.synchronize do
        entry = @input_queue.find { |item| item[:id] == id }
        if entry
          entry[:content] = content
          entry[:options][:display_text] = content if entry[:options][:display_text]
          true
        end
      end
      notify_input_queue
      !!updated
    end

    def remove_pending_input(id)
      removed = @input_mutex.synchronize do
        index = @input_queue.index { |entry| entry[:id] == id }
        @input_queue.delete_at(index) if index
      end
      notify_input_queue
      removed
    end

    def run_pending_input(entry)
      options = entry[:options].dup
      source = options.delete(:source) || :web
      notify_input_queue
      if @ui&.respond_to?(:show_user_message)
        @ui.show_user_message(
          options[:display_text] || entry[:content],
          created_at: options[:created_at],
          files: options[:files] || [],
          source: source,
          steering: true
        )
      end
      run(entry[:content], **options)
    end

    def cancel(reason:)
      return false unless @runtime.respond_to?(:cancel)

      @runtime.cancel(reason: reason)
    end

    def close
      return if @closed

      @closed = true
      @runtime.close if @runtime.respond_to?(:close)
    end

    def change_working_dir(_new_dir)
      raise UnsupportedCapability,
            "agent runtime does not support changing the working directory"
    end

    def fork_runtime_state
      raise UnsupportedCapability, "agent runtime sessions do not support fork"
    end

    def switch_model_by_id(id)
      current = @config&.current_model
      return true if current && current["id"].to_s == id.to_s

      false
    end

    def set_session_sub_model(_model_name)
      raise UnsupportedCapability,
            "agent runtime sessions do not support sub-model overlays"
    end

    def to_session_data(status: :success, error_message: nil, raw_message: nil,
                        updated_at: nil)
      stats = {
        total_tasks: @total_tasks,
        total_iterations: 0,
        total_cost_usd: @total_cost.round(4),
        cost_source: @cost_source.to_s,
        last_status: status.to_s
      }
      stats[:last_error] = error_message if status == :error && error_message
      stats[:last_error_raw] = raw_message if status == :error && raw_message

      card = @config&.current_model || {}
      {
        session_id: @session_id,
        name: @name,
        pinned: @pinned,
        created_at: @created_at,
        updated_at: iso8601(updated_at || Time.now),
        working_dir: @working_dir,
        source: @source.to_s,
        agent_profile: @agent_profile&.name.to_s,
        pending_inputs: pending_inputs,
        todos: @todos,
        config: {
          permission_mode: permission_mode,
          model_id: card["id"],
          provider_id: card["provider_id"]
        },
        runtime: {
          id: @runtime_id,
          version: 1,
          state: runtime_state
        },
        channel_info: @channel_info,
        project_id: @project_id,
        stats: stats,
        messages: @history.to_a
      }
    end

    def replay_history(target_ui, limit: 20, before: nil)
      visible = @history.to_a.reject do |message|
        message[:system_injected] || message[:role].to_s == "system"
      end
      if before
        visible = visible.select do |message|
          !message[:created_at] || message[:created_at].to_f < before.to_f
        end
      end
      user_count = visible.count { |message| message[:role].to_s == "user" }
      has_more = user_count > limit
      if has_more
        allowed_users = 0
        visible = visible.reverse.take_while do |message|
          allowed_users += 1 if message[:role].to_s == "user"
          allowed_users <= limit
        end.reverse
      end

      visible.each do |message|
        case message[:role].to_s
        when "user"
          target_ui.show_user_message(
            message[:display_text] || message[:content],
            created_at: message[:created_at],
            files: Array(message[:display_files]),
            source: :history
          )
        when "assistant"
          target_ui.show_assistant_message(
            message[:content], files: [], created_at: message[:created_at]
          )
        end
      end
      { has_more: has_more }
    end

    private def restore_host_state(data)
      @name = self.class.value(data, :name).to_s
      @pinned = !!self.class.value(data, :pinned)
      @project_id = self.class.value(data, :project_id)
      @channel_info = self.class.value(data, :channel_info)
      @created_at = self.class.value(data, :created_at) || @created_at
      @history = MessageHistory.new(Array(self.class.value(data, :messages)))
      @input_queue = Array(self.class.value(data, :pending_inputs))
      @todos = Array(self.class.value(data, :todos))
      stats = self.class.value(data, :stats) || {}
      @total_tasks = self.class.value(stats, :total_tasks).to_i
      @total_cost = self.class.value(stats, :total_cost_usd).to_f
      source = self.class.value(stats, :cost_source)
      @cost_source = source.to_s.empty? ? :provider : source.to_sym
    end

    private def buffer_assistant_delta(event)
      message_id = (event[:message_id] || event["message_id"] || "assistant").to_s
      content = (event[:content] || event["content"]).to_s
      @generation_mutex.synchronize do
        unless @assistant_buffers.key?(message_id)
          @assistant_buffers[message_id] = String.new
          @assistant_order << message_id
        end
        @assistant_buffers[message_id] << content
      end
    end

    private def finalize_assistant_message(generation, result, started_at)
      text = @generation_mutex.synchronize do
        return unless @current_generation.to_i == generation.to_i

        combined = @assistant_order.map { |id| @assistant_buffers[id] }.join
        combined = (result[:assistant_text] || result["assistant_text"]).to_s if combined.empty?
        combined
      end
      return if text.nil? || text.strip.empty?

      timestamp = Time.now.to_f
      latency = { total_ms: ((Time.now - started_at) * 1000).round }
      @latest_latency = latency
      @history.append(
        role: "assistant", content: text, created_at: timestamp, latency: latency
      )
      @ui&.show_assistant_message(text, files: [], created_at: timestamp)
    end

    private def apply_usage(event)
      cost = event[:cost] || event["cost"] || event[:cost_usd] || event["cost_usd"]
      @total_cost = cost.to_f if cost
      @ui&.show_token_usage(event) if @ui&.respond_to?(:show_token_usage)
    end

    private def refresh_effective_configuration
      state = runtime_state
      self.reasoning_effort = state["reasoning_effort"] if state["reasoning_effort"]
    end

    private def runtime_state
      state = @runtime.respond_to?(:dump_state) ? @runtime.dump_state : {}
      state.is_a?(Hash) ? deep_copy(state) : {}
    end

    private def notify_input_queue
      @ui&.show_input_queue(pending_inputs) if @ui&.respond_to?(:show_input_queue)
    end

    private def next_local_generation
      @generation_mutex.synchronize { @current_generation.to_i + 1 }
    end

    private def iso8601(value)
      value.is_a?(String) ? value : value.iso8601
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
        begin
          value.dup
        rescue TypeError
          value
        end
      end
    end
  end
end
