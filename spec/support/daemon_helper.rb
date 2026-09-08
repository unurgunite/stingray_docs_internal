# frozen_string_literal: true

module DaemonHelper
  def with_idle_daemon(timeout)
    Dir.mktmpdir do |dir|
      sock = "#{dir}/idle.sock"
      daemon = described_class.new(socket_path: sock, idle_timeout: timeout)
      thread = Thread.new { daemon.start }
      sleep 0.1 until File.exist?(sock)
      yield daemon, thread
    end
  end

  def with_cache_dir
    Dir.mktmpdir do |dir|
      test_file = "#{dir}/test.rb"
      daemon = described_class.new(socket_path: "#{dir}/cache.sock", idle_timeout: 60)
      File.write(test_file, "def foo\nend")
      daemon.send(:load_dependencies)
      yield daemon, test_file
    end
  end
end
