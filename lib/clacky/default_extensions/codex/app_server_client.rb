# frozen_string_literal: true

require "base64"
require "uri"
require_relative "json_rpc_client"

module Clacky
  module DefaultExtensions
    module Codex
      # Compatibility boundary between Codex App Server and OpenClacky's
      # runtime-facing session contract. All Codex-specific wire knowledge
      # stays inside the bundled provider.
      class AppServerClient
        NotificationSubscription = Struct.new(:method, :session_id, :handler)

        def initialize(transport:)
          @rpc = JsonRpcClient.new(transport: transport)
          @mutex = Mutex.new
          @notifications = Hash.new { |hash, key| hash[key] = [] }
          @requests = {}
          @sessions = {}
          @active_turns = {}
          @turn_waiters = {}
          @completed_turns = {}
          @models = nil
          install_native_handlers
        end

        def start(client_info:, capabilities: {}, timeout: 15)
          @rpc.start(
            client_info: client_info,
            capabilities: { "experimentalApi" => true },
            timeout: timeout
          )
          self
        end

        def stop
          @rpc.stop
          self
        end

        def initialized?
          @rpc.initialized?
        end

        def alive?
          @rpc.alive?
        end

        def stderr_tail(bytes: 4096)
          @rpc.stderr_tail(bytes: bytes)
        end

        def agent_info
          { "name" => "codex-app-server", "version" => "v2" }
        end

        def agent_capabilities
          { "promptCapabilities" => { "image" => true } }
        end

        def auth_methods
          [{ "id" => "chat-gpt", "name" => "ChatGPT" }]
        end

        def account_status(timeout: 5)
          response = @rpc.request(
            "account/read", { "refreshToken" => false }, timeout: timeout
          )
          account_to_auth_status(response && response["account"])
        end

        def start_chatgpt_login(timeout: 10)
          @rpc.request(
            "account/login/start",
            {
              "type" => "chatgpt",
              "useHostedLoginSuccessPage" => true,
              "appBrand" => "chatgpt"
            },
            timeout: timeout
          )
        end

        def model_catalog(timeout: 15)
          models = []
          cursor = nil
          loop do
            params = { "limit" => 100, "includeHidden" => false }
            params["cursor"] = cursor if cursor
            response = @rpc.request("model/list", params, timeout: timeout)
            models.concat(Array(response && response["data"]))
            cursor = response && response["nextCursor"]
            break if cursor.to_s.empty? || models.length >= 500
          end
          @mutex.synchronize { @models = deep_copy(models) }
          models
        end

        def request(method, params = {}, timeout: nil, before_send: nil,
                    on_sent: nil, on_send_error: nil)
          case method.to_s
          when "authentication/status"
            account_status(timeout: timeout || 5)
          when "session/new"
            open_thread("thread/start", params, timeout: timeout)
          when "session/resume"
            open_thread("thread/resume", params, timeout: timeout)
          when "session/set_config_option"
            set_config_option(params)
          when "session/prompt"
            run_turn(
              params,
              timeout: timeout,
              before_send: before_send,
              on_sent: on_sent,
              on_send_error: on_send_error
            )
          when "session/close"
            close_session(params)
          else
            @rpc.request(
              method, params, timeout: timeout, before_send: before_send,
              on_sent: on_sent, on_send_error: on_send_error
            )
          end
        end

        def notify(method, params = {})
          if method.to_s == "session/cancel"
            interrupt_session(params["sessionId"])
            return nil
          end
          @rpc.notify(method, params)
        end

        def on_notification(method, session_id: nil, &block)
          raise ArgumentError, "notification handler block required" unless block

          subscription = NotificationSubscription.new(method.to_s, session_id&.to_s, block)
          @mutex.synchronize { @notifications[method.to_s] << subscription }
          subscription
        end

        def remove_notification_handler(subscription)
          @mutex.synchronize do
            !!@notifications[subscription.method].delete(subscription)
          end
        end

        def on_request(method, &block)
          raise ArgumentError, "request handler block required" unless block

          @mutex.synchronize { @requests[method.to_s] = block }
          self
        end

        private def install_native_handlers
          @rpc.on_notification("account/updated") do |params|
            emit("_auth/status_update", "authStatus" => account_to_auth_status(params["account"]))
          end
          @rpc.on_notification("account/login/completed") do |params|
            status = if params["success"] == true
                       account_status
                     else
                       { "type" => "unauthenticated", "error" => params["error"] }
                     end
            emit("_auth/status_update", "authStatus" => status)
          rescue StandardError
            emit("_auth/status_update", "authStatus" => { "type" => "unauthenticated" })
          end
          @rpc.on_notification("item/agentMessage/delta") do |params|
            session_update(
              params,
              "sessionUpdate" => "agent_message_chunk",
              "messageId" => params["itemId"],
              "content" => { "type" => "text", "text" => params["delta"].to_s }
            )
          end
          %w[item/reasoning/summaryTextDelta item/reasoning/textDelta].each do |method|
            @rpc.on_notification(method) do |params|
              session_update(
                params,
                "sessionUpdate" => "agent_thought_chunk",
                "content" => { "type" => "text", "text" => params["delta"].to_s }
              )
            end
          end
          @rpc.on_notification("item/started") { |params| item_update(params, completed: false) }
          @rpc.on_notification("item/completed") { |params| item_update(params, completed: true) }
          @rpc.on_notification("turn/completed") { |params| complete_turn(params) }
          @rpc.on_request("item/commandExecution/requestApproval") do |params|
            approval_response(params, kind: "command")
          end
          @rpc.on_request("item/fileChange/requestApproval") do |params|
            approval_response(params, kind: "file_change")
          end
        end

        private def account_to_auth_status(account)
          return { "type" => "unauthenticated" } unless account.is_a?(Hash)

          # The runtime status endpoint is UI metadata, not an account-profile
          # endpoint. Never propagate the user's email through it.
          label = account["planType"].to_s.strip
          result = { "type" => account["type"].to_s.empty? ? "account" : account["type"] }
          result["label"] = label unless label.empty?
          result
        end

        private def open_thread(method, params, timeout:)
          model_catalog(timeout: 15) unless @mutex.synchronize { @models }
          session_id = params["sessionId"].to_s
          config = session_id.empty? ? {} : session_config(session_id)
          request = {
            "cwd" => File.expand_path(params["cwd"].to_s),
            "approvalPolicy" => config["approvalPolicy"] || "on-request",
            "sandbox" => config["sandbox"] || "workspace-write"
          }
          request["threadId"] = session_id unless session_id.empty?
          request["model"] = config["model"] if config["model"]
          response = @rpc.request(method, request, timeout: timeout)
          thread_id = response.dig("thread", "id").to_s
          raise JsonRpcClient::ProtocolError, "Codex App Server did not return a thread id" if thread_id.empty?

          values = config_options(response["model"], response["reasoningEffort"])
          @mutex.synchronize do
            @sessions[thread_id] = {
              "model" => response["model"],
              "reasoning_effort" => response["reasoningEffort"],
              "approvalPolicy" => response["approvalPolicy"],
              "sandbox" => request["sandbox"]
            }
          end
          { "sessionId" => thread_id, "configOptions" => values }
        end

        private def set_config_option(params)
          session_id = params["sessionId"].to_s
          config_id = params["configId"].to_s
          value = params["value"].to_s
          @mutex.synchronize do
            session = (@sessions[session_id] ||= {})
            session[config_id] = value
            if config_id == "mode"
              session["sandbox"] = value == "read-only" ? "read-only" : "workspace-write"
              session["approvalPolicy"] = value == "agent" ? "never" : "on-request"
            end
          end
          { "configOptions" => config_options_for(session_id) }
        end

        private def run_turn(params, timeout:, before_send:, on_sent:, on_send_error:)
          session_id = params["sessionId"].to_s
          config = session_config(session_id)
          request = {
            "threadId" => session_id,
            "input" => translate_input(params["prompt"]),
            "approvalPolicy" => config["approvalPolicy"] || "on-request"
          }
          request["model"] = config["model"] if config["model"]
          request["effort"] = config["reasoning_effort"] if config["reasoning_effort"]
          before_send&.call
          response = @rpc.request(
            "turn/start", request, timeout: 30,
            on_sent: on_sent, on_send_error: on_send_error
          )
          turn_id = response.dig("turn", "id").to_s
          raise JsonRpcClient::ProtocolError, "Codex App Server did not return a turn id" if turn_id.empty?

          queue = Queue.new
          completed = @mutex.synchronize do
            @active_turns[session_id] = turn_id
            @turn_waiters[turn_id] = queue
            @completed_turns.delete(turn_id)
          end
          completed ||= wait_for_turn(queue, timeout)
          turn = completed["turn"] || {}
          status = turn["status"].to_s
          if status == "failed"
            message = turn.dig("error", "message").to_s
            raise JsonRpcClient::ProtocolError, message.empty? ? "Codex turn failed" : message
          end
          {
            "stopReason" => status == "interrupted" ? "cancelled" : "end_turn",
            "usage" => completed["usage"]
          }
        ensure
          @mutex.synchronize do
            @active_turns.delete(session_id) if session_id
            @turn_waiters.delete(turn_id) if turn_id
            @completed_turns.delete(turn_id) if turn_id
          end
        end

        private def wait_for_turn(queue, timeout)
          return queue.pop if timeout.nil?

          Timeout.timeout(timeout) { queue.pop }
        rescue Timeout::Error
          raise JsonRpcClient::RequestTimeout, "Codex turn timed out"
        end

        private def complete_turn(params)
          turn_id = params.dig("turn", "id").to_s
          queue = @mutex.synchronize do
            waiter = @turn_waiters[turn_id]
            @completed_turns[turn_id] = deep_copy(params) unless waiter
            waiter
          end
          queue << deep_copy(params) if queue
        end

        private def interrupt_session(session_id)
          turn_id = @mutex.synchronize { @active_turns[session_id.to_s] }
          return false unless turn_id

          Clacky::ThreadRegistry.spawn(name: "codex-app-server-interrupt", daemon: true) do
            @rpc.request(
              "turn/interrupt",
              { "threadId" => session_id.to_s, "turnId" => turn_id },
              timeout: 5
            )
          rescue StandardError
            nil
          end
          true
        end

        private def close_session(params)
          @mutex.synchronize do
            @sessions.delete(params["sessionId"].to_s)
          end
          {}
        end

        private def translate_input(blocks)
          Array(blocks).filter_map do |block|
            next unless block.is_a?(Hash)

            case block["type"]
            when "text"
              { "type" => "text", "text" => block["text"].to_s }
            when "image"
              mime = block["mimeType"].to_s
              data = block["data"].to_s
              { "type" => "image", "url" => "data:#{mime};base64,#{data}" }
            when "resource_link"
              path = URI(block["uri"].to_s).path
              { "type" => "mention", "name" => block["name"].to_s, "path" => path }
            end
          rescue URI::InvalidURIError
            nil
          end
        end

        private def item_update(params, completed:)
          item = params["item"]
          return unless item.is_a?(Hash)

          update = case item["type"]
                   when "commandExecution"
                     tool_update(item, completed: completed, name: "shell")
                   when "fileChange"
                     tool_update(item, completed: completed, name: "apply_patch")
                   when "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch"
                     tool_update(item, completed: completed, name: item["tool"] || item["type"])
                   when "plan"
                     {
                       "sessionUpdate" => "plan_update",
                       "plan" => { "planId" => item["id"], "content" => item["text"] }
                     }
                   end
          session_update(params, update) if update
        end

        private def tool_update(item, completed:, name:)
          input = item["arguments"] || {}
          if item["type"] == "commandExecution"
            input = { "command" => item["command"], "cwd" => item["cwd"] }
          elsif item["type"] == "fileChange"
            input = { "changes" => item["changes"] }
          end
          {
            "sessionUpdate" => completed ? "tool_call_update" : "tool_call",
            "toolCallId" => item["id"],
            "name" => name,
            "title" => item["command"] || name,
            "rawInput" => input,
            "rawOutput" => item["aggregatedOutput"] || item["result"] || item["error"],
            "status" => completed ? normalize_tool_status(item) : "in_progress"
          }
        end

        private def normalize_tool_status(item)
          status = item["status"].to_s
          %w[failed declined].include?(status) || item["error"] ? "failed" : "completed"
        end

        private def session_update(params, update)
          return unless update

          emit(
            "session/update",
            "sessionId" => params["threadId"],
            "update" => update
          )
        end

        private def approval_response(params, kind:)
          handler = @mutex.synchronize { @requests["session/request_permission"] }
          return { "decision" => "decline" } unless handler

          raw_input = if kind == "command"
                        { "command" => params["command"], "cwd" => params["cwd"] }
                      else
                        { "changes" => params["changes"], "path" => params["grantRoot"] }
                      end
          translated = {
            "sessionId" => params["threadId"],
            "toolCall" => {
              "toolCallId" => params["itemId"],
              "title" => params["reason"],
              "rawInput" => raw_input
            },
            "options" => [
              { "kind" => "allow_once", "optionId" => "allow" },
              { "kind" => "reject_once", "optionId" => "reject" }
            ],
            "_meta" => { "permission" => { "description" => params["reason"] } }
          }
          result = handler.call(translated) || {}
          selected = result.dig("outcome", "optionId")
          { "decision" => selected == "allow" ? "accept" : "decline" }
        end

        private def emit(method, params)
          session_id = params["sessionId"] || params["threadId"]
          handlers = @mutex.synchronize { @notifications[method.to_s].dup }
          handlers.each do |subscription|
            next if subscription.session_id && subscription.session_id != session_id.to_s

            subscription.handler.call(deep_copy(params))
          rescue StandardError
            nil
          end
        end

        private def config_options(model, effort)
          models = @mutex.synchronize { deep_copy(@models || []) }
          model_values = models.reject { |entry| entry["hidden"] == true }.map do |entry|
            { "value" => entry["id"].to_s, "name" => entry["displayName"].to_s }
          end.reject { |entry| entry["value"].empty? }
          efforts = models.find { |entry| entry["id"].to_s == model.to_s }
          effort_values = Array(efforts && efforts["supportedReasoningEfforts"]).map do |entry|
            { "value" => entry["reasoningEffort"].to_s, "name" => entry["reasoningEffort"].to_s }
          end
          [
            { "id" => "model", "currentValue" => model, "options" => model_values },
            { "id" => "reasoning_effort", "currentValue" => effort, "options" => effort_values },
            {
              "id" => "mode", "currentValue" => "read-only",
              "options" => [
                { "value" => "read-only", "name" => "Read only" },
                { "value" => "agent", "name" => "Agent" }
              ]
            }
          ]
        end

        private def config_options_for(session_id)
          config = session_config(session_id)
          options = config_options(config["model"], config["reasoning_effort"])
          mode = config["approvalPolicy"] == "never" ? "agent" : "read-only"
          options.find { |entry| entry["id"] == "mode" }["currentValue"] = mode
          options
        end

        private def session_config(session_id)
          @mutex.synchronize { deep_copy(@sessions[session_id.to_s] || {}) }
        end

        private def deep_copy(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
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
  end
end
