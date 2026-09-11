# frozen_string_literal: true

require "json"
require_relative "codex_home"
require_relative "launcher"

module Clacky
  module DefaultExtensions
    module Codex
      # Owns the shared codex-acp connection, authentication state, and routing
      # for session-scoped notifications and permission requests.
      class Connection
        class UnavailableError < StandardError
          attr_reader :code

          def initialize(code, message)
            @code = code.to_s
            super(message.to_s)
          end
        end

        CONTROL_TIMEOUT = 5
        INITIALIZE_TIMEOUT = 15
        NPX_INITIALIZE_TIMEOUT = 180
        AUTH_STATUS_WAIT = 0.25
        MAX_MESSAGE_BYTES = 8 * 1024 * 1024
        STDERR_BYTES = 16 * 1024

        def initialize(home_manager: nil, launcher_factory: nil,
                       client_factory: nil, thread_spawner: nil)
          @home_manager = home_manager || CodexHome.new
          @launcher_factory = launcher_factory || method(:build_launcher)
          @client_factory = client_factory || method(:build_client)
          @thread_spawner = thread_spawner

          @lifecycle_mutex = Mutex.new
          @state_mutex = Mutex.new
          @state_condition = ConditionVariable.new
          @auth_mutex = Mutex.new
          @sessions_mutex = Mutex.new
          @sessions = {}
          @client = nil
          @generation = 0
          @home_result = nil
          @launcher_result = nil
          @auth_state = nil
          @auth_error = nil
          @authenticating = false
          @auth_thread = nil
          @auth_push_supported = false
        end

        def client_with_generation
          client = ensure_client
          generation = @lifecycle_mutex.synchronize { @generation }
          [client, generation]
        end

        def status
          ensure_client
          wait_for_initial_auth_status if @auth_push_supported
          status_snapshot
        rescue UnavailableError => e
          unavailable_status(e.code, e.message)
        rescue StandardError
          unavailable_status(
            "acp_unavailable",
            "OpenClacky could not start the Codex ACP runtime."
          )
        end

        def health
          snapshot = status
          snapshot.merge(
            ok: snapshot[:available] == true && snapshot[:authenticated] == true,
            message: health_message(snapshot)
          )
        end

        def authenticate_async
          client = ensure_client
          unless client.auth_methods.any? { |method| method["id"].to_s == "chat-gpt" }
            return {
              ok: false,
              started: false,
              status: "unavailable",
              error_code: "chatgpt_auth_unavailable",
              message: "The Codex ACP runtime did not advertise ChatGPT browser login."
            }
          end

          @auth_mutex.synchronize do
            if @auth_thread&.alive?
              return { ok: true, started: false, status: "authenticating" }
            end

            @state_mutex.synchronize do
              @authenticating = true
              @auth_error = nil
              @state_condition.broadcast
            end
            @auth_thread = spawn_thread("codex-acp-authenticate") do
              run_authentication(client)
            end
          end
          { ok: true, started: true, status: "authenticating" }
        rescue UnavailableError => e
          {
            ok: false,
            started: false,
            status: "unavailable",
            error_code: e.code,
            message: e.message
          }
        rescue StandardError
          {
            ok: false,
            started: false,
            status: "error",
            error_code: "authentication_start_failed",
            message: "OpenClacky could not start Codex authentication."
          }
        end

        def bind_session(runtime, session_id, previous_session_id: nil)
          @sessions_mutex.synchronize do
            if previous_session_id && previous_session_id.to_s != session_id.to_s
              @sessions.delete(previous_session_id.to_s)
            end
            @sessions[session_id.to_s] = runtime
          end
        end

        def unbind_session(runtime, session_id: nil)
          @sessions_mutex.synchronize do
            @sessions.delete_if do |id, value|
              value.equal?(runtime) && (session_id.nil? || id == session_id.to_s)
            end
          end
        end

        def close
          client = @lifecycle_mutex.synchronize do
            existing = @client
            @client = nil
            existing
          end
          client&.stop

          thread = @auth_mutex.synchronize { @auth_thread }
          thread&.join(1) unless thread == Thread.current
          @sessions_mutex.synchronize { @sessions.clear }
          @state_mutex.synchronize do
            @authenticating = false
            @auth_state = nil
            @state_condition.broadcast
          end
          nil
        rescue StandardError
          nil
        end

        private def ensure_client
          @lifecycle_mutex.synchronize do
            if @client && @client.initialized? &&
               (!@client.respond_to?(:alive?) || @client.alive?)
              return @client
            end

            old_client = @client
            @client = nil
            old_client&.stop
            start_client
          end
        end

        private def start_client
          home_result = @home_manager.prepare
          launcher = @launcher_factory.call(home_result.managed_home)
          launch = launcher.resolve
          unless launch.available?
            raise UnavailableError.new(
              launch.error_code || "launcher_unavailable",
              launch.message || "Codex ACP launch dependencies are unavailable."
            )
          end

          client = @client_factory.call(launch)
          @home_result = home_result
          @launcher_result = launch
          install_handlers(client)
          reset_connection_auth_state
          client.start(
            client_info: {
              "name" => "openclacky",
              "title" => "OpenClacky",
              "version" => Clacky.const_defined?(:VERSION) ? Clacky::VERSION.to_s : "unknown"
            },
            capabilities: client_capabilities,
            timeout: launch.source == :npx ? NPX_INITIALIZE_TIMEOUT : INITIALIZE_TIMEOUT
          )

          capabilities = client.agent_capabilities
          @auth_push_supported = !capabilities.dig("_meta", "authStatus").nil?
          refresh_legacy_auth_status(client) unless @auth_push_supported
          @generation += 1
          @client = client
        rescue StandardError
          client&.stop rescue nil
          raise
        end

        private def install_handlers(client)
          client.on_notification("_auth/status_update") do |params|
            apply_auth_status(params["authStatus"])
          end
          client.on_notification("session/update") do |params|
            dispatch_session_update(params)
          end
          client.on_request("session/request_permission") do |params|
            dispatch_permission_request(params)
          end
        end

        private def client_capabilities
          {
            "fs" => { "readTextFile" => false, "writeTextFile" => false },
            "terminal" => false,
            "session" => { "configOptions" => { "boolean" => {} } },
            "plan" => {},
            "auth" => { "terminal" => false }
          }
        end

        private def build_launcher(managed_home)
          Launcher.new(
            codex_home: managed_home,
            explicit_path: ENV["CLACKY_CODEX_ACP_PATH"],
            codex_path: ENV["CLACKY_CODEX_PATH"]
          )
        end

        private def build_client(launch)
          transport = Clacky::Acp::ProcessTransport.new(
            name: "codex-acp",
            argv: launch.argv,
            env: launch.env,
            max_message_bytes: MAX_MESSAGE_BYTES,
            stderr_bytes: STDERR_BYTES
          )
          Clacky::Acp::Client.new(transport: transport)
        end

        private def reset_connection_auth_state
          @state_mutex.synchronize do
            @auth_state = nil
            @auth_error = nil
            @authenticating = false
          end
        end

        private def refresh_legacy_auth_status(client)
          result = client.request(
            "authentication/status", {}, timeout: CONTROL_TIMEOUT
          )
          apply_auth_status(result)
        rescue Clacky::Acp::Client::Error
          nil
        end

        private def apply_auth_status(raw_status)
          normalized = normalize_auth_status(raw_status)
          return unless normalized

          @state_mutex.synchronize do
            @auth_state = normalized
            @auth_error = nil
            @state_condition.broadcast
          end
        end

        private def normalize_auth_status(raw_status)
          return nil unless raw_status.is_a?(Hash)

          kind = (raw_status["kind"] || raw_status["type"]).to_s
          case kind
          when "none", "unauthenticated"
            { authenticated: false, kind: kind, label: safe_label(raw_status) }
          when "account", "chat-gpt", "api_key", "api-key", "gateway", "external"
            { authenticated: true, kind: kind, label: safe_label(raw_status) }
          else
            nil
          end
        end

        private def safe_label(raw_status)
          label = raw_status["label"].to_s.strip
          return nil if label.empty?

          label.byteslice(0, 120).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        private def wait_for_initial_auth_status
          @state_mutex.synchronize do
            if @auth_state.nil? && @auth_error.nil? && !@authenticating
              @state_condition.wait(@state_mutex, AUTH_STATUS_WAIT)
            end
          end
        end

        private def status_snapshot
          state = @state_mutex.synchronize do
            {
              auth_state: @auth_state && @auth_state.dup,
              auth_error: @auth_error,
              authenticating: @authenticating
            }
          end
          launch = @launcher_result
          home = @home_result
          auth_state = state[:auth_state]
          status = if state[:authenticating]
                     "authenticating"
                   elsif state[:auth_error]
                     "error"
                   elsif auth_state && auth_state[:authenticated]
                     "connected"
                   elsif auth_state
                     "not_connected"
                   else
                     "unknown"
                   end
          payload = {
            available: true,
            status: status,
            authenticated: auth_state && auth_state[:authenticated],
            auth_reused: home && home.auth_reused == true,
            auth_reason: home && home.auth_reason,
            can_authenticate: current_client_auth_method?("chat-gpt")
          }
          payload[:auth_kind] = auth_state[:kind] if auth_state
          payload[:label] = auth_state[:label] if auth_state && auth_state[:label]
          payload[:launcher] = launch.source.to_s if launch&.source
          payload[:version] = launch.version if launch&.version
          if state[:auth_error]
            payload[:error_code] = "authentication_failed"
            payload[:message] = "Codex authentication did not complete. Try again."
          end
          payload
        end

        private def current_client_auth_method?(method_id)
          client = @client
          client && client.auth_methods.any? { |method| method["id"].to_s == method_id }
        end

        private def unavailable_status(code, message)
          home = @home_result
          {
            available: false,
            status: "unavailable",
            authenticated: nil,
            auth_reused: home && home.auth_reused == true,
            auth_reason: home && home.auth_reason,
            can_authenticate: false,
            error_code: code.to_s,
            message: message.to_s
          }
        end

        private def health_message(snapshot)
          return snapshot[:message] if snapshot[:message]
          return "Codex is connected." if snapshot[:authenticated] == true
          return "Connect a ChatGPT account to use Codex." if snapshot[:authenticated] == false

          "Waiting for Codex authentication status."
        end

        private def run_authentication(client)
          client.request(
            "authenticate", { "methodId" => "chat-gpt" }, timeout: nil
          )
          @state_mutex.synchronize do
            @auth_state ||= {
              authenticated: true,
              kind: "account",
              label: "ChatGPT"
            }
            @auth_error = nil
          end
        rescue StandardError
          @state_mutex.synchronize { @auth_error = true }
        ensure
          @state_mutex.synchronize do
            @authenticating = false
            @state_condition.broadcast
          end
        end

        private def dispatch_session_update(params)
          runtime = @sessions_mutex.synchronize do
            @sessions[params["sessionId"].to_s]
          end
          runtime&.handle_session_update(params)
        end

        private def dispatch_permission_request(params)
          runtime = @sessions_mutex.synchronize do
            @sessions[params["sessionId"].to_s]
          end
          return runtime.handle_permission_request(params) if runtime

          Runtime.rejected_permission_response(params)
        end

        private def spawn_thread(name, &block)
          return @thread_spawner.call(name, &block) if @thread_spawner

          if defined?(Clacky::ThreadRegistry)
            Clacky::ThreadRegistry.spawn(name: name, daemon: true, &block)
          else
            Thread.new(&block)
          end
        end
      end

      # Implements one OpenClacky agent-runtime instance over a shared ACP v1
      # connection. The host remains authoritative for transcript and queueing.
      class Runtime
        class Error < StandardError; end
        class BusyError < Error; end
        class UnsupportedInput < Error; end

        CONTROL_TIMEOUT = 5
        MAX_THOUGHT_BYTES = 8 * 1024

        class << self
          def connection
            connection_mutex.synchronize do
              @connection ||= Connection.new
            end
          end

          def connection=(value)
            connection_mutex.synchronize { @connection = value }
          end

          def status
            connection.status
          end

          def authenticate_async
            connection.authenticate_async
          end

          def shutdown
            existing = connection_mutex.synchronize do
              value = @connection
              @connection = nil
              value
            end
            existing&.close
          end

          def rejected_permission_response(params)
            options = Array(params && params["options"])
            rejection = options.find { |option| option["kind"].to_s == "reject_once" } ||
                        options.find { |option| option["kind"].to_s.start_with?("reject") }
            if rejection
              {
                "outcome" => {
                  "outcome" => "selected",
                  "optionId" => rejection["optionId"]
                }
              }
            else
              { "outcome" => { "outcome" => "cancelled" } }
            end
          end

          private def connection_mutex
            @connection_mutex ||= Mutex.new
          end
        end

        def initialize(context: nil, persisted_state: nil, purpose: nil,
                       connection: nil, **_options)
          @context = context || {}
          @purpose = purpose && purpose.to_sym
          @connection = connection || self.class.connection
          @persisted_session_id = value(persisted_state, "session_id")
          @saved_model = value(persisted_state, "model")
          @saved_reasoning_effort = value(persisted_state, "reasoning_effort")
          @external_session_id = @persisted_session_id.to_s
          @external_session_id = nil if @external_session_id.empty?
          @config_options = []
          @client_generation = nil
          @active_generation = nil
          @state_mutex = Mutex.new
          @run_mutex = Mutex.new
          @in_flight = false
          @closed = false
          @tools = {}
        end

        def health
          @connection.health
        end

        def capabilities
          {
            cancel: true,
            image_input: true,
            plans: true,
            time_machine: false,
            sub_model: false,
            fork: false
          }
        end

        def run(input, generation:)
          reserved = false
          reserve_turn!
          reserved = true
          @state_mutex.synchronize { @active_generation = generation.to_i }
          client = ensure_external_session
          prompt = build_prompt(input, client)
          result = client.request(
            "session/prompt",
            { "sessionId" => external_session_id, "prompt" => prompt },
            timeout: nil
          )
          {
            stop_reason: result["stopReason"],
            awaiting_user_feedback: false
          }
        ensure
          if reserved
            @state_mutex.synchronize { @active_generation = nil }
            @run_mutex.synchronize { @in_flight = false }
          end
        end

        def cancel(reason:)
          session_id = external_session_id
          return false unless session_id

          client, = @connection.client_with_generation
          client.notify("session/cancel", "sessionId" => session_id)
          ui = @context[:ui]
          if ui&.respond_to?(:cancel_pending_confirmations)
            ui.cancel_pending_confirmations(result: false)
          end
          true
        rescue StandardError
          false
        end

        def close
          return if @closed

          busy = @run_mutex.synchronize { @in_flight }
          cancel(reason: :close) if busy
          session_id = external_session_id
          @connection.unbind_session(self, session_id: session_id)
          unless busy || session_id.nil?
            begin
              client, = @connection.client_with_generation
              client.request(
                "session/close", { "sessionId" => session_id }, timeout: CONTROL_TIMEOUT
              )
            rescue StandardError
              nil
            end
          end
          @closed = true
          nil
        end

        def dump_state
          session_id = external_session_id
          return {} unless session_id

          state = { "session_id" => session_id }
          model = current_config_value("model")
          effort = current_config_value("reasoning_effort")
          state["model"] = model if model
          state["reasoning_effort"] = effort if effort
          state
        end

        def handle_session_update(params)
          update = params && params["update"]
          return unless update.is_a?(Hash)

          update_type = update["sessionUpdate"].to_s
          replace_config_options(update["configOptions"]) if update_type == "config_option_update"
          event = normalize_update(update_type, update)
          return unless event

          generation = @state_mutex.synchronize do
            @closed ? nil : @active_generation
          end
          emit_event(generation, event) if generation
        end

        def handle_permission_request(params)
          options = Array(params && params["options"])
          allow = options.find { |option| option["kind"].to_s == "allow_once" }
          reject = options.find { |option| option["kind"].to_s == "reject_once" }
          title = params.dig("toolCall", "title").to_s.strip
          title = "Allow this Codex action?" if title.empty?
          ui = @context[:ui]
          approved = if ui&.respond_to?(:request_confirmation)
                       ui.request_confirmation(title, default: false) == true
                     else
                       false
                     end
          selected = approved ? allow : reject
          if selected
            {
              "outcome" => {
                "outcome" => "selected",
                "optionId" => selected["optionId"]
              }
            }
          else
            self.class.rejected_permission_response(params)
          end
        rescue StandardError
          self.class.rejected_permission_response(params)
        end

        private def reserve_turn!
          @run_mutex.synchronize do
            raise Error, "Codex runtime is closed" if @closed
            raise BusyError, "Codex session already has an in-flight prompt" if @in_flight

            @in_flight = true
          end
        end

        private def ensure_external_session
          client, generation = @connection.client_with_generation
          return client if @client_generation == generation && external_session_id

          old_session_id = external_session_id
          if old_session_id
            begin
              response = client.request(
                "session/resume",
                session_open_params(old_session_id),
                timeout: CONTROL_TIMEOUT
              )
              accept_opened_session(client, generation, old_session_id, response)
              restore_effective_configuration(client)
              return client
            rescue Clacky::Acp::Client::ProtocolError
              emit_event(active_generation, type: :warning, code: "resume_failed")
              @connection.unbind_session(self, session_id: old_session_id)
              @state_mutex.synchronize { @external_session_id = nil }
            end
          end

          response = client.request(
            "session/new", session_open_params, timeout: CONTROL_TIMEOUT
          )
          session_id = response["sessionId"].to_s
          raise Error, "Codex ACP did not return a session id" if session_id.empty?

          accept_opened_session(client, generation, session_id, response,
                                previous_session_id: old_session_id)
          client
        end

        private def session_open_params(session_id = nil)
          params = {
            "cwd" => File.expand_path(@context[:working_dir] || Dir.pwd),
            "mcpServers" => []
          }
          params["sessionId"] = session_id if session_id
          params
        end

        private def accept_opened_session(client, generation, session_id, response,
                                          previous_session_id: nil)
          @state_mutex.synchronize do
            @external_session_id = session_id
            @client_generation = generation
          end
          @connection.bind_session(
            self, session_id, previous_session_id: previous_session_id
          )
          replace_config_options(response["configOptions"])
          apply_permission_mode(client)
        end

        private def restore_effective_configuration(client)
          apply_saved_config_value(client, "model", @saved_model)
          apply_saved_config_value(
            client, "reasoning_effort", @saved_reasoning_effort
          )
          @saved_model = nil
          @saved_reasoning_effort = nil
        end

        private def apply_saved_config_value(client, config_id, saved_value)
          value_to_apply = saved_value.to_s
          return if value_to_apply.empty?

          option = config_option(config_id)
          return unless option && advertised_value?(option, value_to_apply)
          return if option["currentValue"].to_s == value_to_apply

          set_config_value(client, config_id, value_to_apply)
        end

        private def apply_permission_mode(client)
          requested = @context[:permission_mode].to_s
          target = case requested
                   when "auto_approve"
                     "agent"
                   when "confirm_all", "confirm_edits", "confirm_safes"
                     "read-only"
                   end
          return unless target

          option = config_option("mode")
          return unless option && advertised_value?(option, target)
          return if option["currentValue"].to_s == target

          set_config_value(client, "mode", target)
        end

        private def set_config_value(client, config_id, value_to_apply)
          response = client.request(
            "session/set_config_option",
            {
              "sessionId" => external_session_id,
              "configId" => config_id,
              "value" => value_to_apply
            },
            timeout: CONTROL_TIMEOUT
          )
          replace_config_options(response["configOptions"])
        end

        private def advertised_value?(option, requested)
          flatten_options(option["options"]).any? do |candidate|
            candidate["value"].to_s == requested.to_s
          end
        end

        private def flatten_options(options)
          Array(options).each_with_object([]) do |entry, flattened|
            next unless entry.is_a?(Hash)

            if entry["options"].is_a?(Array)
              flattened.concat(flatten_options(entry["options"]))
            else
              flattened << entry
            end
          end
        end

        private def replace_config_options(options)
          return unless options.is_a?(Array)

          copy = deep_copy(options.select { |option| option.is_a?(Hash) })
          @state_mutex.synchronize { @config_options = copy }
        end

        private def config_option(config_id)
          @state_mutex.synchronize do
            option = @config_options.find { |entry| entry["id"].to_s == config_id }
            option && deep_copy(option)
          end
        end

        private def current_config_value(config_id)
          option = config_option(config_id)
          value = option && option["currentValue"]
          string = value.to_s.strip
          string.empty? ? nil : string
        end

        private def build_prompt(input, client)
          blocks = []
          content = input.content.to_s
          blocks << { "type" => "text", "text" => content } unless content.empty?
          Array(input.reference_contexts).each do |reference|
            text = reference.is_a?(String) ? reference : JSON.generate(reference)
            blocks << { "type" => "text", "text" => "[Reference context]\n#{text}" }
          end

          files = Array(input.files)
          unless files.empty?
            supports_images = client.agent_capabilities.dig(
              "promptCapabilities", "image"
            ) == true
            files.each do |file|
              image = image_block(file)
              if image
                raise UnsupportedInput, "Codex ACP does not support image input" unless supports_images

                blocks << image
              else
                raise UnsupportedInput, "Codex ACP cannot represent this attachment"
              end
            end
          end
          blocks
        rescue JSON::GeneratorError
          raise UnsupportedInput, "Codex ACP cannot represent the supplied context"
        end

        private def image_block(file)
          return nil unless file.is_a?(Hash)

          data_url = (file["data_url"] || file[:data_url]).to_s
          match = data_url.match(/\Adata:([^;,]+);base64,(.*)\z/m)
          return nil unless match && match[1].start_with?("image/")

          {
            "type" => "image",
            "mimeType" => match[1],
            "data" => match[2]
          }
        end

        private def normalize_update(update_type, update)
          case update_type
          when "agent_message_chunk"
            {
              type: :assistant_delta,
              message_id: update["messageId"] || "assistant",
              content: content_text(update["content"])
            }
          when "agent_thought_chunk"
            { type: :thought, content: bounded_text(content_text(update["content"])) }
          when "tool_call"
            @tools[update["toolCallId"].to_s] = deep_copy(update)
            tool_call_event(update)
          when "tool_call_update"
            normalize_tool_update(update)
          when "plan"
            { type: :plan, entries: deep_copy(Array(update["entries"])) }
          when "plan_update"
            plan = update["plan"].is_a?(Hash) ? update["plan"] : {}
            { type: :plan, entries: deep_copy(Array(plan["entries"])), plan: deep_copy(plan) }
          when "usage_update"
            {
              type: :usage,
              used: update["used"],
              size: update["size"],
              cost: deep_copy(update["cost"])
            }
          when "session_info_update"
            {
              type: :session_info,
              title: update["title"],
              updated_at: update["updatedAt"]
            }
          when "config_option_update"
            nil
          else
            { type: :unknown, session_update: update_type }
          end
        end

        private def normalize_tool_update(update)
          id = update["toolCallId"].to_s
          current = @tools[id] || {}
          merged = current.merge(deep_copy(update))
          @tools[id] = merged
          if %w[completed failed].include?(merged["status"].to_s)
            {
              type: :tool_result,
              tool_call_id: id,
              result: merged.key?("rawOutput") ? deep_copy(merged["rawOutput"]) : deep_copy(merged["content"]),
              status: merged["status"]
            }
          else
            tool_call_event(merged)
          end
        end

        private def tool_call_event(update)
          {
            type: :tool_call,
            tool_call_id: update["toolCallId"].to_s,
            name: update["name"] || update["title"] || update["kind"] || "tool",
            input: deep_copy(update["rawInput"] || {})
          }
        end

        private def content_text(content)
          return "" unless content.is_a?(Hash)
          return content["text"].to_s if content["type"] == "text"

          resource = content["resource"]
          resource.is_a?(Hash) ? resource["text"].to_s : ""
        end

        private def bounded_text(text)
          value = text.to_s
          return value if value.bytesize <= MAX_THOUGHT_BYTES

          value.byteslice(0, MAX_THOUGHT_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub
        end

        private def emit_event(generation, event)
          sink = @context[:event_sink]
          sink.call(generation, event) if generation && sink.respond_to?(:call)
        end

        private def active_generation
          @state_mutex.synchronize { @active_generation }
        end

        private def external_session_id
          @state_mutex.synchronize { @external_session_id }
        end

        private def value(hash, key)
          return nil unless hash.is_a?(Hash)

          hash[key] || hash[key.to_sym]
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
  end
end
