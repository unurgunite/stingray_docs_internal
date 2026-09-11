# frozen_string_literal: true

require 'socket'

module DaemonRequestHelper
  # Run update_types twice via socket and capture results.
  #
  # @param [String] socket_path daemon socket path
  # @param [String] dir project directory
  # @return [Array<Hash<String, Object>, String, Hash<String, Object>>]
  def run_update_types_twice(socket_path, dir)
    first = send_raw_request(socket_path, 'update_types', { 'dir' => dir })
    content = File.read("#{dir}/x.rb")
    second = send_raw_request(socket_path, 'update_types', { 'dir' => dir })
    [first, content, second]
  end

  # Send a raw JSON-RPC request to a daemon socket and parse the response.
  #
  # @param [String] socket_path path to the Unix socket
  # @param [String] method JSON-RPC method name
  # @param [Hash<String, Object>] params request params
  # @return [Hash<String, Object>, nil] parsed response
  def send_raw_request(socket_path, method, params = {})
    socket = UNIXSocket.new(socket_path)
    req = Docscribe::Server::Protocol.build_request(method, params)
    socket.write(Docscribe::Server::Protocol.serialize(req))
    socket.close_write
    line = socket.gets
    socket.close
    Docscribe::Server::Protocol.parse_response(line)
  end

  # Full environment for update_types integration test.
  #
  # @yield [String, String] dir and socket path
  # @return [void]
  def with_update_types_env
    with_tmp_dir do |dir|
      prepare_update_types_fixture(dir)
      sock = "#{dir}/upd.sock"
      with_isolated_update_types_daemon(dir, sock) do |socket_path|
        yield dir, socket_path
      end
    end
  end

  # Prepare a minimal fixture for update_types with missing lock file.
  #
  # @param [String] dir temporary directory
  # @return [void]
  def prepare_update_types_fixture(dir)
    File.write("#{dir}/x.rb", "class X\n  def foo(x)\n    x\n  end\nend\n")
    FileUtils.rm_f("#{dir}/rbs_collection.lock.yaml")
    FileUtils.rm_rf("#{dir}/.gem_rbs_collection")
  end

  # Setup a temporary isolated daemon for update_types tests.
  #
  # @param [String] dir temporary directory
  # @param [String] socket_path daemon socket
  # @yield [String] socket path inside Dir.chdir
  # @return [void]
  def with_isolated_update_types_daemon(dir, socket_path)
    daemon = described_class.new(socket_path: socket_path, idle_timeout: 60)
    daemon.send(:load_dependencies)
    thread = Thread.new { daemon.start }
    sleep 0.2 until File.exist?(socket_path)
    Dir.chdir(dir) { yield socket_path }
  ensure
    suppress_error { Docscribe::Server::Client.new(socket_path).shutdown }
    suppress_error { thread&.join(2) }
  end
end
