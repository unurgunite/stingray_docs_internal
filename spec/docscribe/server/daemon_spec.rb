# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/NestedGroups

require 'docscribe/server'
require 'docscribe/cli/update_types'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'

RSpec.describe Docscribe::Server::Daemon do
  let!(:socket_path) { "#{Dir.mktmpdir}/docscribe-test.sock" }
  let!(:test_file) do
    path = "#{File.dirname(socket_path)}/test.rb"
    File.write(path, <<~RUBY)
      def hello
        puts 'world'
      end
    RUBY
    path
  end

  let!(:daemon) { described_class.new(socket_path: socket_path, idle_timeout: 60) }
  let!(:daemon_thread) { Thread.new { daemon.start } }
  let(:client) { Docscribe::Server::Client.new(socket_path) }

  before { sleep 0.5 }

  after do
    suppress_error { Docscribe::Server::Client.new(socket_path).shutdown }
    suppress_error { daemon_thread.join(3) }
    FileUtils.remove_entry(File.dirname(socket_path))
  end

  describe '#start' do
    it 'creates a socket file' do
      aggregate_failures do
        expect(File.exist?(socket_path)).to be true
        expect(File.exist?("#{socket_path}.pid")).to be true
      end
    end
  end

  describe 'check request' do
    subject(:response) { client.check(file: checked_file) }

    let(:checked_file) { test_file }

    context 'with a clean file' do
      let(:checked_file) { create_clean_file(socket_path) }

      it 'returns ok for a file with no issues' do
        aggregate_failures do
          expect(response).not_to be_nil
          expect(response['result'].slice('status', 'changed')).to eq('status' => 'ok', 'changed' => false)
        end
      end
    end

    context 'with a nonexistent file' do
      let(:checked_file) { '/nonexistent.rb' }

      it 'returns error for a nonexistent file' do
        aggregate_failures do
          expect(response).not_to be_nil
          expect(response.dig('error', 'message')).to include('File not found')
        end
      end
    end

    it 'returns fail for a file needing updates' do
      aggregate_failures do
        expect(response).not_to be_nil
        expect(response['result']['status']).to eq('fail')
      end
    end

    it 'defaults to safe strategy when not specified', :aggregate_failures do
      expect(response).not_to be_nil
      expect(response['error']).to be_nil
      expect(response['result']).to have_key('status')
    end
  end

  describe 'fix request' do
    subject(:response) { client.fix(file: test_file) }

    it 'returns success status' do
      aggregate_failures do
        expect(response).not_to be_nil
        expect(response['result']['status']).to eq('ok')
      end
    end

    it 'writes corrected content to the file' do
      before_fix = File.read(test_file)
      client.fix(file: test_file)
      after_fix = File.read(test_file)
      expect([after_fix != before_fix, after_fix.include?('@return')]).to eq([true, true])
    end
  end

  describe 'shutdown request' do
    subject(:response) { client.shutdown }

    it 'responds to shutdown request' do
      aggregate_failures do
        expect(response).not_to be_nil
        expect(response['result']['status']).to eq('shutting_down')
      end
    end

    it 'removes the socket after shutdown' do
      client.shutdown
      sleep 0.3
      expect(File.exist?(socket_path)).to be false
    end
  end

  describe 'ping request' do
    let(:ping_response) { client.ping }

    it 'responds to ping' do
      expect(ping_response).not_to be_nil
    end

    it 'returns version' do
      expect(ping_response.dig('result', 'version')).to eq(Docscribe::VERSION)
    end

    it 'returns pid' do
      expect(ping_response.dig('result', 'pid')).to eq(Process.pid)
    end

    it 'returns socket_path' do
      expect(ping_response.dig('result', 'socket_path')).to eq(socket_path)
    end

    it 'returns started_at as an ISO8601 string' do
      expect(ping_response.dig('result', 'started_at')).to be_a(String)
    end

    it 'returns uptime as an integer' do
      expect(ping_response.dig('result', 'uptime')).to be_a(Integer)
    end
  end

  describe 'idle timeout' do
    it 'stops the daemon when idle timeout expires' do
      with_idle_daemon(0.3) do |_daemon, thread|
        expect(thread.join(2)).to be(thread)
      end
    end
  end

  describe 'file cache' do
    let(:override_hash) do
      {
        'no_boilerplate' => true,
        'include' => [],
        'exclude' => [],
        'include_file' => [],
        'exclude_file' => [],
        'sig_dirs' => [],
        'rbi_dirs' => []
      }
    end

    it 'caches across repeated calls' do
      with_cache_dir do |daemon, test_file|
        orig = daemon.send(:rewrite_file, test_file, :safe)
        allow(Docscribe::InlineRewriter).to receive(:rewrite_with_report) { raise 'called twice' }
        expect(daemon.send(:rewrite_file, test_file, :safe)).to eq(orig)
      end
    end

    it 'clears cache when cli overrides change' do
      with_cache_dir do |daemon, test_file|
        daemon.send(:rewrite_file, test_file, :safe)
        daemon.send(:apply_cli_overrides, override_hash)
        expect(daemon.instance_variable_get(:@file_cache)).to be_empty
      end
    end

    it 'sets effective_config when overrides applied' do
      with_cache_dir do |daemon, _test_file|
        daemon.send(:apply_cli_overrides, override_hash)
        expect(daemon.instance_variable_get(:@effective_config)).not_to be_nil
      end
    end

    it 'records applied_overrides' do
      with_cache_dir do |daemon, _test_file|
        daemon.send(:apply_cli_overrides, override_hash)
        expect(daemon.instance_variable_get(:@applied_overrides)).to eq(override_hash)
      end
    end

    it 'unsets effective_config when overrides become nil' do
      with_cache_dir do |daemon, _test_file|
        daemon.send(:apply_cli_overrides, override_hash)
        daemon.send(:apply_cli_overrides, nil)
        expect(daemon.instance_variable_get(:@effective_config)).to be_nil
      end
    end

    it 'unsets applied_overrides when overrides become nil' do
      with_cache_dir do |daemon, _test_file|
        daemon.send(:apply_cli_overrides, override_hash)
        daemon.send(:apply_cli_overrides, nil)
        expect(daemon.instance_variable_get(:@applied_overrides)).to be_nil
      end
    end

    it 'clears cache when overrides become nil' do
      with_cache_dir do |daemon, _test_file|
        daemon.send(:apply_cli_overrides, override_hash) && daemon.send(:apply_cli_overrides, nil)
        expect(daemon.instance_variable_get(:@file_cache)).to be_empty
      end
    end
  end

  describe 'rbs sig cache invalidation' do
    context 'when RBS is available' do
      before { skip_unless_rbs_available! }

      it 'initially includes Integer param' do
        with_tmp_dir do |dir|
          r1, = sig_pair_after_change(dir)
          expect(r1).to include('@param [Integer]')
        end
      end

      it 'after sig change includes String param' do
        with_tmp_dir do |dir|
          _, r2 = sig_pair_after_change(dir)
          expect(r2).to include('@param [String]')
        end
      end

      it 'changes output after sig change' do
        with_tmp_dir do |dir|
          r1, r2 = sig_pair_after_change(dir)
          expect(r1).not_to eq(r2)
        end
      end

      it 'new file initially includes Integer' do
        with_tmp_dir do |dir|
          r1, = sig_pair_new_file(dir)
          expect(r1).to include('@param [Integer]')
        end
      end

      it 'new file after sig change includes String' do
        with_tmp_dir do |dir|
          _, r2 = sig_pair_new_file(dir)
          expect(r2).to include('@param [String]')
        end
      end

      it 'caches rewritten result' do
        with_tmp_dir do |dir|
          _, r2, r3 = sig_triple_cached(dir)
          expect(r3).to eq(r2)
        end
      end

      it 'changes cached output after sig change' do
        with_tmp_dir do |dir|
          r1, _, r3 = sig_triple_cached(dir)
          expect(r1).not_to eq(r3)
        end
      end
    end

    context 'without RBS dependency' do
      it 'stores sig_hash in cache entry' do
        with_tmp_dir do |dir|
          hit, = cache_hit_for(dir)
          expect(hit).to include(:sig_hash)
        end
      end

      it 'stores correct sig_hash value' do
        with_tmp_dir do |dir|
          hit, daemon, config = cache_hit_for(dir)
          expect(hit[:sig_hash]).to eq(daemon.send(:sig_hash_for, config))
        end
      end

      it 'sig_hash_for respects custom sig_dirs' do
        with_tmp_dir do |dir|
          h_custom, h_default = custom_vs_default_hashes(dir)
          expect(h_custom).not_to eq(h_default)
        end
      end

      it 'sig_dirs_for falls back to sig when empty' do
        with_tmp_dir do |dir|
          daemon = build_plain_daemon(dir)
          config = Docscribe::Config.new('rbs' => { 'enabled' => true, 'sig_dirs' => [] })
          expect(daemon.send(:sig_dirs_for, config)).to eq(['sig'])
        end
      end

      it 'sig_hash changes when new sig file added' do
        with_tmp_dir do |dir|
          h1, h2 = sig_hash_pair(dir)
          expect(h1).not_to eq(h2)
        end
      end
    end
  end

  describe 'update_types request' do
    it 'returns ok when UpdateTypes.run succeeds' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['.']).and_return(0)
      resp = client.update_types
      expect(resp).to include('result' => hash_including('status' => 'ok', 'dir' => '.', 'exit_code' => 0))
    end

    it 'respects dir param' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['lib']).and_return(0)
      expect(client.update_types(dir: 'lib')['result']['dir']).to eq('lib')
    end

    it 'respects directory param via raw request' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['app']).and_return(0)
      resp = send_raw_request(socket_path, 'update_types', { 'directory' => 'app' })
      expect(resp['result']['dir']).to eq('app')
    end

    it 'defaults to . when dir not provided' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['.']).and_return(0)
      resp = send_raw_request(socket_path, 'update_types', {})
      expect(resp['result']['dir']).to eq('.')
    end

    it 'returns error when exit_code non-zero' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).and_return(2)
      resp = client.update_types
      expect(resp['error']).to include('code' => Docscribe::Server::Daemon::ERROR_CODES[:internal], 'message' => include('exit code 2'), 'data' => hash_including('exit_code' => 2))
    end

    it 'clears file cache after success' do
      daemon.instance_variable_get(:@file_cache)[%w[test.rb safe]] =
        { mtime: Time.now, sig_hash: '0', src: '', result: {} }
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).and_return(0)
      client.update_types
      expect(daemon.instance_variable_get(:@file_cache)).to be_empty
    end

    it 'applies cli_overrides without error for minimal hash' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).and_return(0)
      resp = send_raw_request(socket_path, 'update_types',
                              { 'cli_overrides' => { 'no_boilerplate' => true } })
      expect(resp['result']['status']).to eq('ok')
    end

    it 'handles exception and returns internal error' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).and_raise(StandardError, 'boom')
      resp = client.update_types
      expect(resp['error']).to include('code' => Docscribe::Server::Daemon::ERROR_CODES[:internal], 'message' => include('boom'))
    end

    it 'does not return Unknown method for update_types' do
      allow(Docscribe::CLI::UpdateTypes).to receive(:run).and_return(0)
      expect(client.update_types['result']['status']).to eq('ok')
    end

    context 'when passing custom dir' do
      before do
        allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['custom_dir']).and_return(0)
      end

      let(:custom_resp) { send_raw_request(socket_path, 'update_types', { 'dir' => 'custom_dir' }) }

      it 'passes dir to UpdateTypes.run' do
        custom_resp
        expect(Docscribe::CLI::UpdateTypes).to have_received(:run).with(['custom_dir'])
      end

      it 'returns dir in response' do
        expect(custom_resp['result']['dir']).to eq('custom_dir')
      end
    end

    context 'with real filesystem and missing rbs_collection.lock.yaml' do
      it 'returns ok and warns instead of failing' do
        with_update_types_env do |dir, sock|
          first, content, second = run_update_types_twice(sock, dir)
          expect([first['result']['status'], content.include?('@return'),
                  second['result']['status']]).to eq(['ok', true, 'ok'])
        end
      end
    end

    describe 'private helpers' do
      let(:io) { StringIO.new }
      let(:parsed) { JSON.parse(io.string) }
      let(:run_result) { daemon.send(:run_update_types, 'lib') }

      it 'update_types_dir prefers dir over directory' do
        expect(daemon.send(:update_types_dir, { 'dir' => 'a', 'directory' => 'b' })).to eq('a')
      end

      it 'update_types_dir falls back to directory' do
        expect(daemon.send(:update_types_dir, { 'directory' => 'b' })).to eq('b')
      end

      it 'update_types_dir defaults to .' do
        expect(daemon.send(:update_types_dir, {})).to eq('.')
      end

      it 'run_update_types delegates to CLI' do
        allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['lib']).and_return(0)
        expect(run_result).to eq(0)
      end

      it 'send_update_types_response sends ok for zero exit' do
        daemon.send(:send_update_types_response, io, 1, '.', 0)
        expect(parsed['result']).to include('status' => 'ok', 'exit_code' => 0)
      end

      it 'send_update_types_response sends error for non-zero exit' do
        daemon.send(:send_update_types_response, io, 1, '.', 1)
        expect(parsed['error']['code']).to eq(Docscribe::Server::Daemon::ERROR_CODES[:internal])
      end
    end

    describe 'REQUEST_HANDLERS dispatch' do
      let(:tmp_dir) { Dir.mktmpdir }
      let(:dispatch_daemon) { described_class.new(socket_path: "#{tmp_dir}/dispatch.sock", idle_timeout: 60) }
      let(:client_io) { StringIO.new }
      let(:request_id) { 42 }

      after { FileUtils.remove_entry(tmp_dir) }

      describe '#dispatch_request' do
        context 'when method is check' do
          let(:method) { 'check' }
          let(:params) { { 'file' => '/tmp/a.rb' } }
          let(:request) { { 'id' => request_id, 'method' => method, 'params' => params } }

          it 'dispatches to handle_check' do
            allow(dispatch_daemon).to receive(:handle_check)
            dispatch_daemon.send(:dispatch_request, client_io, request, method, params)
            expect(dispatch_daemon).to have_received(:handle_check).with(client_io, request_id, params)
          end
        end

        context 'when method is fix' do
          let(:method) { 'fix' }
          let(:params) { { 'file' => '/tmp/b.rb' } }
          let(:request) { { 'id' => request_id, 'method' => method, 'params' => params } }

          it 'dispatches to handle_fix' do
            allow(dispatch_daemon).to receive(:handle_fix)
            dispatch_daemon.send(:dispatch_request, client_io, request, method, params)
            expect(dispatch_daemon).to have_received(:handle_fix).with(client_io, request_id, params)
          end
        end

        context 'when method is check_batch' do
          let(:method) { 'check_batch' }
          let(:params) { { 'files' => ['/tmp/a.rb'] } }
          let(:request) { { 'id' => request_id, 'method' => method, 'params' => params } }

          it 'dispatches to handle_check_batch' do
            allow(dispatch_daemon).to receive(:handle_check_batch)
            dispatch_daemon.send(:dispatch_request, client_io, request, method, params)
            expect(dispatch_daemon).to have_received(:handle_check_batch).with(client_io, request_id, params)
          end
        end

        context 'when method is update_types' do
          let(:method) { 'update_types' }
          let(:params) { { 'dir' => '.' } }
          let(:request) { { 'id' => request_id, 'method' => method, 'params' => params } }

          it 'dispatches to handle_update_types' do
            allow(dispatch_daemon).to receive(:handle_update_types)
            dispatch_daemon.send(:dispatch_request, client_io, request, method, params)
            expect(dispatch_daemon).to have_received(:handle_update_types).with(client_io, request_id, params)
          end
        end

        context 'when method is unknown and falls to control' do
          let(:method) { 'unknown_method' }
          let(:params) { {} }
          let(:request) { { 'id' => request_id, 'method' => method, 'params' => params } }

          it 'dispatches to dispatch_control_request' do
            allow(dispatch_daemon).to receive(:dispatch_control_request)
            dispatch_daemon.send(:dispatch_request, client_io, request, method, params)
            expect(dispatch_daemon).to have_received(:dispatch_control_request).with(client_io, request, method)
          end
        end
      end

      describe '#dispatch_control_request' do
        context 'when method is shutdown' do
          let(:method) { 'shutdown' }
          let(:request) { { 'id' => request_id } }

          it 'dispatches to handle_shutdown' do
            allow(dispatch_daemon).to receive(:handle_shutdown)
            dispatch_daemon.send(:dispatch_control_request, client_io, request, method)
            expect(dispatch_daemon).to have_received(:handle_shutdown).with(client_io, request_id)
          end
        end

        context 'when method is ping' do
          let(:method) { 'ping' }
          let(:request) { { 'id' => request_id } }

          it 'dispatches to handle_ping' do
            allow(dispatch_daemon).to receive(:handle_ping)
            dispatch_daemon.send(:dispatch_control_request, client_io, request, method)
            expect(dispatch_daemon).to have_received(:handle_ping).with(client_io, request_id)
          end
        end

        context 'when method is unknown' do
          subject(:response) do
            dispatch_daemon.send(:dispatch_control_request, client_io, request, method)
            JSON.parse(client_io.string)
          end

          let(:method) { 'foobar' }
          let(:request) { { 'id' => request_id } }

          it 'returns unknown method error with code -32601' do
            expect(response['error']['code']).to eq(-32_601)
          end

          it 'includes method name in message' do
            expect(response['error']['message']).to include('Unknown method')
            expect(response['error']['message']).to include(method)
          end
        end
      end

      describe '#handle_request routing' do
        let(:method) { 'check' }
        let(:params) { { 'file' => '/tmp/a.rb' } }
        let(:request) { { 'method' => method, 'params' => params, 'id' => request_id } }

        it 'delegates to dispatch_request' do
          allow(dispatch_daemon).to receive(:dispatch_request)
          dispatch_daemon.send(:handle_request, client_io, request)
          expect(dispatch_daemon).to have_received(:dispatch_request).with(client_io, request, method, params)
        end

        context 'when params missing' do
          let(:request) { { 'method' => method, 'id' => request_id } }

          it 'defaults params to empty hash' do
            allow(dispatch_daemon).to receive(:dispatch_request)
            dispatch_daemon.send(:handle_request, client_io, request)
            expect(dispatch_daemon).to have_received(:dispatch_request).with(client_io, request, method, {})
          end
        end
      end
    end

    describe 'run_rewrite transform_keys stringification' do
      let(:tmp_dir2) { Dir.mktmpdir }
      let(:validate_overrides) do
        {
          'validate_types' => true, 'include' => [], 'exclude' => [],
          'include_file' => [], 'exclude_file' => [], 'sig_dirs' => [],
          'rbi_dirs' => [], 'no_boilerplate' => true
        }
      end
      let(:rw_daemon) { described_class.new(socket_path: "#{tmp_dir2}/rw.sock", idle_timeout: 60) }

      before do
        rw_daemon.send(:load_dependencies)
      end

      after { FileUtils.remove_entry(tmp_dir2) }

      context 'with infer source mismatch' do
        subject(:result) do
          rw_daemon.send(:apply_cli_overrides, validate_overrides)
          rw_daemon.send(:run_rewrite, file_path, :safe)
        end

        let(:ruby_source) do
          <<~RUBY
            class Foo
              # @return [Integer]
              def bar
                "hello"
              end
            end
          RUBY
        end
        let(:file_path) do
          path = File.join(tmp_dir2, 'a.rb')
          File.write(path, ruby_source)
          path
        end

        it 'has string keys type and source', :aggregate_failures do
          expect(result['changes'].first).to have_key('type')
          expect(result['changes'].first).to have_key('source')
          expect(result['changes'].first.keys).to all(be_a(String))
        end

        it 'has no symbol keys', :aggregate_failures do
          expect(result['changes'].first).not_to have_key(:type)
          expect(result['changes'].first).not_to have_key(:source)
        end

        it 'has source infer as string' do
          expect(result['changes'].first['source']).to eq('infer')
        end

        it 'has type as updated_return stringified' do
          expect(result['changes'].first['type'].to_s).to eq('updated_return')
        end
      end

      context 'with syntax source invalid YARD' do
        subject(:result) do
          rw_daemon.send(:apply_cli_overrides, validate_overrides)
          rw_daemon.send(:run_rewrite, file_path, :safe)
        end

        let(:ruby_source) do
          <<~RUBY
            class Foo
              # @return [Sym bol]
              def bar
                :x
              end
            end
          RUBY
        end
        let(:file_path) do
          path = File.join(tmp_dir2, 'b.rb')
          File.write(path, ruby_source)
          path
        end

        it 'has source syntax stringified' do
          expect(result['changes'].first['source']).to eq('syntax')
        end

        it 'has type invalid_type' do
          expect(result['changes'].first['type'].to_s).to eq('invalid_type')
        end

        it 'has string keys' do
          expect(result['changes'].first.keys).to include('type', 'source')
        end
      end

      context 'when dispatched via check_batch' do
        subject(:batch_response) do
          first = File.join(tmp_dir2, 'c.rb')
          second = File.join(tmp_dir2, 'd.rb')
          File.write(first, <<~RUBY)
            class A
              # @return [Integer]
              def foo
                "hi"
              end
            end
          RUBY
          File.write(second, <<~RUBY)
            class B
              # @return [Sym bol]
              def bar
                :x
              end
            end
          RUBY
          rw_daemon.send(:apply_cli_overrides, validate_overrides)
          io = StringIO.new
          rw_daemon.send(:handle_check_batch, io, 1, { 'files' => [first, second] })
          JSON.parse(io.string)['result']['results']
        end

        it 'returns batch results with stringified changes', :aggregate_failures do
          expect(batch_response.size).to eq(2)
          expect(batch_response[0]['changes'].first['source']).to eq('infer')
          expect(batch_response[1]['changes'].first['source']).to eq('syntax')
          expect(batch_response[0]['changes'].first.keys).to include('type', 'source')
          expect(batch_response[1]['changes'].first.keys).to include('type', 'source')
        end

        it 'has type stringified via to_s' do
          expect(batch_response[0]['changes'].first['type'].to_s).to eq('updated_return')
          expect(batch_response[1]['changes'].first['type'].to_s).to eq('invalid_type')
        end
      end
    end

    describe 'REQUEST_HANDLERS constant' do
      subject(:handlers) { described_class::REQUEST_HANDLERS }

      it 'includes check handler' do
        expect(handlers['check']).to eq(:handle_check)
      end

      it 'includes fix handler' do
        expect(handlers['fix']).to eq(:handle_fix)
      end

      it 'includes check_batch handler' do
        expect(handlers['check_batch']).to eq(:handle_check_batch)
      end

      it 'includes update_types handler' do
        expect(handlers['update_types']).to eq(:handle_update_types)
      end
    end
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/NestedGroups
