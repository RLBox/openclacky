# frozen_string_literal: true

require "timeout"

module Clacky
  module Acp
    # Concurrent JSON-RPC client for ACP v1 transports.
    class Client
      class Error < StandardError; end
      class TransportError < Error; end
      class ProtocolError < Error; end
      class RequestTimeout < Error; end

      PROTOCOL_VERSION = 1
      INITIALIZE_TIMEOUT = 15
      NotificationSubscription = Struct.new(:method, :session_id, :handler)

      attr_reader :initialize_result

      def initialize(transport:)
        @transport = transport
        @next_id = 0
        @pending = {}
        @notification_handlers = Hash.new { |hash, key| hash[key] = [] }
        @request_handlers = {}
        @lock = Mutex.new
        @started = false
        @initialize_result = {}

        @transport.on_message { |message| handle_message(message) }
      end

      def start(client_info:, capabilities: {}, timeout: INITIALIZE_TIMEOUT)
        return self if initialized?

        @transport.start
        result = raw_request(
          "initialize",
          {
            protocolVersion: PROTOCOL_VERSION,
            clientCapabilities: capabilities,
            clientInfo: client_info
          },
          timeout: timeout
        )
        unless result["protocolVersion"].to_i == PROTOCOL_VERSION
          raise ProtocolError,
                "ACP initialize returned unsupported protocol version #{result['protocolVersion'].inspect}"
        end

        @lock.synchronize do
          @initialize_result = result
          @started = true
        end
        self
      rescue StandardError
        @transport.stop rescue nil
        raise
      end

      def stop
        @lock.synchronize { @started = false }
        fail_pending("ACP client stopped")
        @transport.stop
        self
      rescue StandardError
        self
      end

      def initialized?
        @lock.synchronize { @started }
      end

      def alive?
        initialized? && @transport.alive?
      end

      def agent_info
        @lock.synchronize { deep_copy(@initialize_result["agentInfo"] || {}) }
      end

      def agent_capabilities
        @lock.synchronize { deep_copy(@initialize_result["agentCapabilities"] || {}) }
      end

      def auth_methods
        @lock.synchronize { deep_copy(@initialize_result["authMethods"] || []) }
      end

      def request(method, params = {}, timeout: nil)
        ensure_started!
        raw_request(method, params, timeout: timeout)
      end

      def notify(method, params = {})
        ensure_started!
        @transport.send_message(jsonrpc: "2.0", method: method, params: params)
        nil
      rescue StandardError => e
        raise_transport_error(e)
      end

      def on_notification(method, session_id: nil, &block)
        raise ArgumentError, "notification handler block required" unless block

        subscription = NotificationSubscription.new(
          method.to_s,
          session_id && session_id.to_s,
          block
        )
        @lock.synchronize do
          @notification_handlers[method.to_s] << subscription
        end
        subscription
      end

      def remove_notification_handler(subscription)
        return false unless subscription.is_a?(NotificationSubscription)

        @lock.synchronize do
          handlers = @notification_handlers[subscription.method]
          !!handlers.delete(subscription)
        end
      end

      def on_request(method, &block)
        raise ArgumentError, "request handler block required" unless block

        @lock.synchronize { @request_handlers[method.to_s] = block }
        self
      end

      def pending_request_count
        @lock.synchronize { @pending.length }
      end

      def stderr_tail(bytes: 4096)
        @transport.stderr_tail(bytes: bytes)
      end

      private def raw_request(method, params, timeout:)
        queue = Queue.new
        id = @lock.synchronize do
          @next_id += 1
          @pending[@next_id] = { queue: queue, method: method.to_s }
          @next_id
        end

        begin
          @transport.send_message(
            jsonrpc: "2.0", id: id, method: method.to_s, params: params
          )
        rescue StandardError => e
          @lock.synchronize { @pending.delete(id) }
          raise_transport_error(e)
        end

        response = if timeout.nil?
                     queue.pop
                   else
                     Timeout.timeout(timeout) { queue.pop }
                   end
        raise response[:exception] if response.is_a?(Hash) && response[:exception]

        if (remote_error = response["error"])
          message = remote_error["message"].to_s
          code = remote_error["code"]
          raise ProtocolError,
                "ACP request '#{method}' failed: #{message} (code #{code})"
        end

        response["result"] || {}
      rescue Timeout::Error
        raise RequestTimeout, "ACP request '#{method}' timed out"
      ensure
        @lock.synchronize { @pending.delete(id) } if id
      end

      private def handle_message(message)
        unless message.is_a?(Hash)
          return
        end

        if message["__transport_closed__"]
          fail_pending(message["error"].to_s.empty? ? "ACP transport closed" : message["error"])
          return
        end

        if message["__transport_error__"]
          fail_pending(message["error"].to_s.empty? ? "ACP transport failed" : message["error"])
          return
        end

        if message.key?("id") && !message.key?("method")
          pending = @lock.synchronize { @pending.delete(message["id"]) }
          pending[:queue] << message if pending
          return
        end

        if message.key?("id") && message["method"]
          dispatch_reverse_request(message)
          return
        end

        dispatch_notification(message) if message["method"]
      end

      private def dispatch_notification(message)
        method = message["method"].to_s
        params = message["params"] || {}
        session_id = params["sessionId"] || params["session_id"]
        handlers = @lock.synchronize { Array(@notification_handlers[method]).dup }

        handlers.each do |subscription|
          expected_session_id = subscription.session_id
          next if expected_session_id && expected_session_id != session_id.to_s

          subscription.handler.call(params)
        rescue StandardError => e
          Clacky::Logger.warn(
            "[ACP] notification handler failed",
            method: method,
            error: e.class.name
          ) if defined?(Clacky::Logger)
        end
      end

      private def dispatch_reverse_request(message)
        id = message["id"]
        method = message["method"].to_s
        params = message["params"] || {}
        handler = @lock.synchronize { @request_handlers[method] }

        unless handler
          @transport.send_message(
            jsonrpc: "2.0",
            id: id,
            error: { code: -32_601, message: "Method not found" }
          )
          return
        end

        spawn_handler_thread(method) do
          begin
            result = handler.call(params) || {}
            @transport.send_message(jsonrpc: "2.0", id: id, result: result)
          rescue StandardError => e
            Clacky::Logger.warn(
              "[ACP] request handler failed",
              method: method,
              error: e.class.name
            ) if defined?(Clacky::Logger)
            @transport.send_message(
              jsonrpc: "2.0",
              id: id,
              error: { code: -32_603, message: "Internal error" }
            )
          end
        end
      rescue StandardError => e
        Clacky::Logger.warn(
          "[ACP] failed to dispatch reverse request",
          method: method,
          error: e.class.name
        ) if defined?(Clacky::Logger)
      end

      private def spawn_handler_thread(method, &block)
        if defined?(Clacky::ThreadRegistry)
          Clacky::ThreadRegistry.spawn(
            name: "acp-request:#{method}", daemon: true, &block
          )
        else
          Thread.new(&block)
        end
      end

      private def fail_pending(message)
        exception = TransportError.new(message.to_s)
        pending = @lock.synchronize do
          values = @pending.values
          @pending.clear
          values
        end
        pending.each { |entry| entry[:queue] << { exception: exception } }
      end

      private def ensure_started!
        raise TransportError, "ACP client is not initialized" unless initialized?
        raise TransportError, "ACP transport is not running" unless @transport.alive?
      end

      private def raise_transport_error(error)
        raise error if error.is_a?(Error)

        raise TransportError, "ACP transport error: #{error.class}: #{error.message}"
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
