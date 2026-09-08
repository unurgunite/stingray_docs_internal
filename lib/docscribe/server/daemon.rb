# frozen_string_literal: true

require 'socket'
require 'fileutils'
require 'time'
require 'timeout'
require 'digest/md5'
require_relative '../lru_cache'

module Docscribe
  module Server
    # Daemon process that loads the Ruby runtime once and serves requests.
    class Daemon
      # Standardized JSON-RPC error codes.
      ERROR_CODES = {
        gem_not_found: -32_000,
        syntax_error: -32_001,
        config_load_failure: -32_002,
        timeout: -32_010,
        internal: -32_099
      }.freeze

      REQUEST_HANDLERS = {
        'check' => :handle_check,
        'fix' => :handle_fix,
        'check_batch' => :handle_check_batch,
        'update_types' => :handle_update_types
      }.freeze

      # @param [String?] socket_path custom socket path
      # @param [Integer] idle_timeout seconds before automatic shutdown
      # @param [String?] config_path custom config path
      # @return [void]
      def initialize(socket_path: nil, idle_timeout: IDLE_TIMEOUT, config_path: nil)
        setup_socket_config(socket_path, config_path, idle_timeout)
        setup_runtime_state
        setup_caches
      end

      # @param [String?] socket_path
      # @param [String?] config_path
      # @param [Integer] idle_timeout
      # @return [void]
      def setup_socket_config(socket_path, config_path, idle_timeout)
        @socket_path = socket_path || Server.socket_path(config_path)
        @config_path = config_path
        @idle_timeout = idle_timeout
      end

      # @return [void]
      def setup_runtime_state
        @last_request_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @running = false
        @server = nil
        @started_at = Time.now
        @last_sig_hash = nil
      end

      # @return [void]
      def setup_caches
        @file_cache = LRUCache.new
        @cache_mutex = Mutex.new
        @config_mutex = Mutex.new
      end

      # Start the daemon: load dependencies, bind socket, enter listen loop.
      #
      # @return [void]
      def start
        load_dependencies
        setup_socket
        @running = true
        $PROGRAM_NAME = "docscribe server (#{Dir.pwd})"
        write_pid
        listen_loop
      end

      private

      # Load the full Docscribe runtime and build cached config.
      #
      # @private
      # @return [void]
      def load_dependencies
        require 'docscribe'
        @config = Docscribe::Config.load(@config_path)
        @config&.load_plugins!
        @core_rbs_provider = @config&.core_rbs_provider
      end

      # Create and bind the Unix domain socket.
      #
      # @private
      # @return [void]
      def setup_socket
        FileUtils.rm_f(@socket_path)
        FileUtils.mkdir_p(File.dirname(@socket_path))
        @server = UNIXServer.new(@socket_path)
        File.chmod(0o600, @socket_path)
      end

      # @private
      # @return [void]
      def write_pid
        File.write("#{@socket_path}.pid", Process.pid)
      end

      # Main accept loop with idle timeout check.
      #
      # @private
      # @raise [Interrupt]
      # @return [void]
      def listen_loop
        while @running
          check_idle_timeout
          accept_client
        end
      rescue Interrupt
        @running = false
      ensure
        cleanup
      end

      # Check whether the idle timeout has been exceeded.
      #
      # @private
      # @return [void]
      def check_idle_timeout
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request_time
        @running = false if elapsed > @idle_timeout
      end

      # Accept a client connection if one is available.
      # Spawns a thread to handle each client concurrently.
      #
      # @private
      # @return [void]
      def accept_client
        client = @server&.accept if @server&.wait_readable(0.1)
        return unless client

        @last_request_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Thread.new(client) { |conn| handle_client(conn) }
      end

      # Read a request from a client connection and dispatch it.
      #
      # @private
      # @param [UNIXSocket] client connected client socket
      # @raise [StandardError]
      # @return [void]
      def handle_client(client)
        request_line = client.gets or return
        request = Protocol.parse_response(request_line)
        request ? handle_request(client, request) : send_error(client, nil, -32_700, 'Parse error')
      rescue StandardError => e
        method_name = request&.dig('method')
        error_params = request&.dig('params') || {}
        code, message, data = classify_error(e, method_name, error_params)
        send_error(client, request&.dig('id'), code, message, data)
      ensure
        client.close
      end

      # Dispatch a parsed request to the appropriate handler.
      #
      # @private
      # @param [UNIXSocket] client connected client socket
      # @param [Hash<String, Object>] request parsed JSON-RPC request
      # @return [void]
      def handle_request(client, request)
        method = request['method']
        params = request['params'] || {}
        dispatch_request(client, request, method, params)
      end

      # @private
      # @param [UNIXSocket] client
      # @param [Hash<String, Object>] request
      # @param [String] method
      # @param [Hash<String, Object>] params
      # @return [void]
      def dispatch_request(client, request, method, params)
        handler = REQUEST_HANDLERS[method]
        return send(handler, client, request['id'], params) if handler

        dispatch_control_request(client, request, method)
      end

      # @private
      # @param [UNIXSocket] client
      # @param [Hash<String, Object>] request
      # @param [String] method
      # @return [void]
      def dispatch_control_request(client, request, method)
        case method
        when 'shutdown' then handle_shutdown(client, request['id'])
        when 'ping' then handle_ping(client, request['id'])
        else send_error(client, request['id'], -32_601, "Unknown method: #{method}")
        end
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer] id
      # @param [Hash<String, Object>] params
      # @raise [StandardError]
      # @return [void]
      # @return [void] if StandardError
      def handle_check(client, id, params)
        file = params['file']
        strategy = (params['strategy'] || 'safe').to_sym
        return send_error(client, id, -32_602, "File not found: #{file}") unless file && File.file?(file)

        apply_cli_overrides(params['cli_overrides'])
        src, result = rewrite_file(file, strategy)
        send_result(client, id, 'status' => result[:output] == src ? 'ok' : 'fail',
                                'changed' => result[:output] != src, 'changes' => result[:changes])
      rescue StandardError => e
        handle_request_error(client, id, e, file)
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer] id
      # @param [Hash<String, Object>] params
      # @raise [StandardError]
      # @return [void]
      # @return [void] if StandardError
      def handle_fix(client, id, params)
        file = params['file']
        strategy = (params['strategy'] || 'safe').to_sym
        return send_error(client, id, -32_602, "File not found: #{file}") unless file && File.file?(file)

        apply_cli_overrides(params['cli_overrides'])
        src, result = rewrite_file(file, strategy)
        changed = result[:output] != src
        File.write(file, result[:output]) if changed
        send_result(client, id, 'status' => 'ok', 'changed' => changed, 'changes' => result[:changes])
      rescue StandardError => e
        handle_request_error(client, id, e, file)
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer] id
      # @param [Hash<String, Object>] params
      # @return [void]
      def handle_check_batch(client, id, params)
        files = params['files']
        return send_error(client, id, -32_602, 'Missing files parameter') unless files.is_a?(Array) && !files.empty?

        strategy = (params['strategy'] || 'safe').to_sym
        timeout = params['timeout']

        apply_cli_overrides(params['cli_overrides'])

        results = files.map do |file|
          process_file_in_batch(file, strategy, timeout)
        end

        send_result(client, id, { 'results' => results })
      end

      # @private
      # @param [String] file
      # @param [Symbol] strategy
      # @param [Integer, Float?] timeout
      # @raise [Timeout::Error]
      # @raise [StandardError]
      # @return [Hash<String, Object>]
      # @return [Hash] if Timeout::Error
      # @return [Hash] if StandardError
      def process_file_in_batch(file, strategy, timeout = nil)
        return { 'file' => file, 'status' => 'error', 'error' => "File not found: #{file}" } unless File.file?(file)

        if timeout
          Timeout.timeout(timeout.to_f) { run_rewrite(file, strategy) }
        else
          run_rewrite(file, strategy)
        end
      rescue Timeout::Error
        { 'file' => file, 'status' => 'error', 'error' => 'Timeout' }
      rescue StandardError => e
        { 'file' => file, 'status' => 'error', 'error' => "#{e.class}: #{e.message}" }
      end

      # @private
      # @param [String] file
      # @param [Symbol] strategy
      # @return [Hash<String, Object>]
      def run_rewrite(file, strategy)
        src, result = rewrite_file(file, strategy)
        changes = result[:changes].map { |c| c.transform_keys(&:to_s) }
        { 'file' => file, 'status' => result[:output] == src ? 'ok' : 'fail', 'changes' => changes }
      end

      # @private
      # @param [Hash<String, Object>?] overrides
      # @return [void]
      def apply_cli_overrides(overrides) # rubocop:disable SortedMethodsByCall/Waterfall
        @config_mutex.synchronize do
          return reset_effective_config_internal if overrides.nil? || overrides.empty?
          return if @applied_overrides == overrides

          build_effective_config(overrides)
        end
      end

      # @private
      # @param [Hash<String, Object>] overrides
      # @return [void]
      def build_effective_config(overrides)
        config = @config or return
        require 'docscribe/cli/config_builder'
        require 'docscribe/cli/options'
        opts = Docscribe::CLI::Options::DEFAULT.merge(overrides.transform_keys(&:to_sym))
        @effective_config = Docscribe::CLI::ConfigBuilder.build(config, opts)
        @file_cache.clear
        @applied_overrides = overrides
      end

      # @private
      # @return [void]
      def reset_effective_config
        @config_mutex.synchronize { reset_effective_config_internal }
      end

      # @private
      # @return [void]
      def reset_effective_config_internal
        return unless @effective_config

        @effective_config = nil
        @applied_overrides = nil
        @file_cache.clear
      end

      # @private
      # @param [String] file
      # @param [Symbol] strategy
      # @raise [StandardError]
      # @return [(String, Hash<Symbol, String, Array<Hash<Symbol, Object>>>)]
      def rewrite_file(file, strategy)
        @cache_mutex.synchronize do
          config = @effective_config || @config or raise 'Docscribe: config not loaded'
          key = [file, strategy]
          mtime = File.mtime(file)
          sig_hash = sig_hash_for(config)
          handle_sig_change(sig_hash)
          cached = cached_result(key, mtime, sig_hash)
          return cached if cached

          rewrite_and_cache(file, strategy, config, key, mtime)
        end
      end

      # @private
      # @param [String] sig_hash
      # @return [void]
      def handle_sig_change(sig_hash)
        if @last_sig_hash && @last_sig_hash != sig_hash
          [@config, @effective_config].compact.each { |c| clear_rbs_cache(c) }
          @file_cache.clear
        end
        @last_sig_hash = sig_hash
      end

      # @private
      # @param [Array<String, Symbol>] key
      # @param [Time] mtime
      # @param [String] sig_hash
      # @return [(String, Hash<Symbol, String, Array<Hash<Symbol, Object>>>)?]
      def cached_result(key, mtime, sig_hash)
        hit = @file_cache[key]
        return nil unless hit && hit[:mtime] == mtime && hit[:sig_hash] == sig_hash

        [hit[:src], hit[:result]]
      end

      # Clear memoized RBS providers so next request rebuilds env with fresh sig files.
      #
      # @private
      # @param [Docscribe::Config] config
      # @raise [StandardError]
      # @return [void]
      # @return [nil] if StandardError
      def clear_rbs_cache(config)
        config.instance_variable_set(:@rbs_provider, nil) if config.instance_variable_defined?(:@rbs_provider)
        config.instance_variable_set(:@core_rbs_provider, nil) if config.instance_variable_defined?(:@core_rbs_provider)
      rescue StandardError
        nil
      end

      # @private
      # @param [String] file
      # @param [Symbol] strategy
      # @param [Docscribe::Config] config effective or base config
      # @param [Array<String, Symbol>] key cache key
      # @param [Time] mtime file modification time
      # @return [(String, Hash<Symbol, String, Array<Hash<Symbol, Object>>>)]
      def rewrite_and_cache(file, strategy, config, key, mtime)
        src = File.read(file)
        rbs = config.respond_to?(:core_rbs_provider) ? config.core_rbs_provider : nil
        result = Docscribe::InlineRewriter.rewrite_with_report(src, strategy: strategy, config: config,
                                                                    core_rbs_provider: rbs, file: file)
        @file_cache[key] = { mtime: mtime, sig_hash: @last_sig_hash, src: src, result: result }
        [src, result]
      end

      # Hash of RBS signature files for cache invalidation.
      # Includes all files under sig_dirs (default: sig/**/*.rbs).
      #
      # @private
      # @param [Docscribe::Config] config effective or base config
      # @raise [StandardError]
      # @return [String]
      # @return [String] if StandardError
      def sig_hash_for(config)
        files = sig_rbs_files(sig_dirs_for(config))
        parts = files.map { |p| "#{p}:#{File.mtime(p).to_f}" if File.file?(p) }.compact
        parts << "count:#{files.size}"
        Digest::MD5.hexdigest(parts.join('|'))
      rescue StandardError
        '0'
      end

      # @private
      # @param [Array<String>] dirs
      # @return [Array<String>]
      def sig_rbs_files(dirs)
        dirs.flat_map { |dir| Dir.glob(File.join(Dir.pwd, dir, '**', '*.rbs')) }.uniq.sort
      end

      # Resolve sig dirs from config, falling back to defaults.
      #
      # @private
      # @param [Docscribe::Config] config
      # @raise [StandardError]
      # @return [Array<String>]
      # @return [Array] if StandardError
      def sig_dirs_for(config)
        raw_dirs = config.raw.dig('rbs', 'sig_dirs') if config.respond_to?(:raw)
        dirs = Array(raw_dirs || Docscribe::Config::DEFAULT.dig('rbs', 'sig_dirs')).map(&:to_s) # steep:ignore
        dirs.empty? ? ['sig'] : dirs
      rescue StandardError
        ['sig']
      end

      # Handle update_types request (used by RubyMine plugin).
      #
      # @private
      # @param [UNIXSocket] client connected client socket
      # @param [String, Integer] id request ID
      # @param [Hash<String, Object>] params request params
      # @raise [StandardError]
      # @return [void]
      # @return [void] if StandardError
      def handle_update_types(client, id, params)
        target = update_types_dir(params)
        apply_cli_overrides(params['cli_overrides'])
        exit_code = run_update_types(target)
        @file_cache.clear
        send_update_types_response(client, id, target, exit_code)
      rescue StandardError => e
        @file_cache.clear
        code, message, data = classify_error(e, 'update_types', params)
        send_error(client, id, code, message, data)
      end

      # @private
      # @param [Hash<String, Object>] params
      # @return [String]
      def update_types_dir(params)
        params['file'] || params['dir'] || params['directory'] || '.'
      end

      # @private
      # @param [String] target
      # @return [Integer]
      def run_update_types(target)
        require 'docscribe/cli/update_types'
        Docscribe::CLI::UpdateTypes.run([target])
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer] id
      # @param [String] dir
      # @param [Integer] exit_code
      # @return [void]
      def send_update_types_response(client, id, dir, exit_code)
        if exit_code.zero?
          send_result(client, id, 'status' => 'ok', 'dir' => dir, 'exit_code' => exit_code)
        else
          send_error(client, id, ERROR_CODES[:internal], "update_types failed with exit code #{exit_code}",
                     { 'dir' => dir, 'exit_code' => exit_code })
        end
      end

      # Handle a shutdown request.
      #
      # @private
      # @param [UNIXSocket] client connected client socket
      # @param [String, Integer] id request ID
      # @return [void]
      def handle_shutdown(client, id)
        send_result(client, id, { 'status' => 'shutting_down' })
        @running = false
      end

      # Handle a ping request.
      #
      # @private
      # @param [UNIXSocket] client connected client socket
      # @param [String, Integer] id request ID
      # @return [void]
      def handle_ping(client, id)
        uptime = (Time.now - @started_at).to_i
        send_result(client, id, {
                      'version' => Docscribe::VERSION,
                      'pid' => Process.pid,
                      'socket_path' => @socket_path,
                      'started_at' => @started_at.iso8601,
                      'uptime' => uptime
                    })
      end

      # Send a JSON-RPC result response.
      #
      # @private
      # @param [UNIXSocket] client connected client socket
      # @param [String, Integer] id request ID
      # @param [Hash<String, Object>] result result data
      # @return [void]
      def send_result(client, id, result)
        response = { jsonrpc: '2.0', id: id, result: result }
        client.write(Protocol.serialize(response))
      end

      # @private
      # @param [Exception] exception
      # @param [String?] _method_name
      # @param [Hash<String, Object>] params
      # @return [(Integer, String, Hash<Symbol, Object, nil>, nil)]
      def classify_error(exception, _method_name = nil, params = {})
        if exception.is_a?(LoadError) || exception.is_a?(Gem::LoadError)
          classify_gem_error(exception)
        elsif syntax_error?(exception)
          classify_syntax_err(exception, params)
        elsif timeout_error?(exception)
          classify_timeout_err(exception, params)
        else
          classify_internal_err(exception)
        end
      end

      # @private
      # @param [Exception] exception
      # @return [Boolean]
      def syntax_error?(exception)
        exception.is_a?(Docscribe::ParseError) ||
          (defined?(Parser::SyntaxError) && exception.is_a?(Parser::SyntaxError))
      end

      # @private
      # @param [Exception] exception
      # @return [Boolean]
      def timeout_error?(exception)
        !!defined?(Timeout::Error) && exception.is_a?(Timeout::Error)
      end

      # @private
      # @param [Exception] exception
      # @return [(Integer, String, Hash<Symbol, String, nil>)]
      def classify_gem_error(exception)
        data = { gem: nil }
        data[:gem] = exception.path if exception.respond_to?(:path) && exception.path
        [ERROR_CODES[:gem_not_found], "#{exception.class}: #{exception.message}", data]
      end

      # @private
      # @param [Exception] exception
      # @param [Hash<String, Object>] params
      # @return [(Integer, String, Hash<Symbol, Object>)]
      def classify_syntax_err(exception, params)
        file = (params['file'] if params.is_a?(Hash)).to_s
        line = if exception.respond_to?(:line)
                 exception.line
               elsif exception.respond_to?(:diagnostic)
                 exception.diagnostic.location.line
               end
        data = { file: file, detail: exception.message, line: line }.compact
        [ERROR_CODES[:syntax_error], "Syntax error in #{file}", data]
      end

      # @private
      # @param [Exception] exception
      # @param [Hash<String, Object>] params
      # @return [(Integer, String, Hash<Symbol, Object>)]
      def classify_timeout_err(exception, params)
        file = (params['file'] if params.is_a?(Hash)).to_s
        data = { timeout: @idle_timeout || 30, file: file }
        [ERROR_CODES[:timeout], "#{exception.class}: #{exception.message}", data]
      end

      # @private
      # @param [Exception] exception
      # @return [(Integer, String, Hash<Symbol, Object>)]
      def classify_internal_err(exception)
        backtrace = exception.backtrace&.first(5) || []
        data = { backtrace: backtrace }
        [ERROR_CODES[:internal], "#{exception.class}: #{exception.message}", data]
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer] id
      # @param [Exception] exception
      # @param [String] file
      # @raise [StandardError]
      # @return [void]
      def handle_request_error(client, id, exception, file)
        if exception.is_a?(Docscribe::ParseError) ||
           (defined?(Parser::SyntaxError) && exception.is_a?(Parser::SyntaxError))
          send_syntax_error(client, id, exception, file)
        else
          raise
        end
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer] id
      # @param [Exception] exception
      # @param [String] file
      # @return [void]
      def send_syntax_error(client, id, exception, file)
        line = if exception.respond_to?(:line)
                 exception.line
               elsif exception.respond_to?(:diagnostic)
                 exception.diagnostic.location.line
               end
        data = { file: file, detail: exception.message, line: line }.compact
        send_error(client, id, ERROR_CODES[:syntax_error], "Syntax error in #{file}", data)
      end

      # @private
      # @param [UNIXSocket] client
      # @param [String, Integer, nil] id
      # @param [Integer] code
      # @param [String] message
      # @param [Hash<Symbol, Object>?] data optional structured error data
      # @return [void]
      def send_error(client, id, code, message, data = nil)
        error = { code: code, message: message }
        error[:data] = data if data
        response = { jsonrpc: '2.0', id: id, error: error }
        client.write(Protocol.serialize(response))
      end

      # Cleanup socket and PID files on shutdown.
      #
      # @private
      # @raise [StandardError]
      # @return [void]
      # @return [nil] if StandardError
      def cleanup
        @server&.close
        File.unlink(@socket_path) if @socket_path && File.exist?(@socket_path)
        pid_path = "#{@socket_path}.pid"
        FileUtils.rm_f(pid_path)
      rescue StandardError
        nil
      end
    end
  end
end
