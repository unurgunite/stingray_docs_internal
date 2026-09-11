# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'securerandom'
require 'rbconfig'
require 'docscribe/cli'

RSpec.describe Docscribe::CLI do
  describe 'server subcommand' do
    describe 'without arguments' do
      let(:dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(dir) }

      it 'prints usage to stderr' do
        _out, err, st = Open3.capture3(RbConfig.ruby, exe, 'server', chdir: dir)
        aggregate_failures do
          expect(err).to include('Usage: docscribe server <command>')
          expect(st.exitstatus).to eq(1)
        end
      end
    end

    describe 'status' do
      let(:dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(dir) }

      it 'reports not running initially' do
        _out, err, st = Open3.capture3(RbConfig.ruby, exe, 'server', 'status', chdir: dir)
        aggregate_failures do
          expect(err).to include('not running')
          expect(st.exitstatus).to eq(0)
        end
      end
    end

    describe 'with --config / -C' do
      let(:dir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(dir) }

      it 'status -C works' do
        _out, err, st = Open3.capture3(RbConfig.ruby, exe, 'server', 'status', '-C', 'nonexistent.yml', chdir: dir)
        aggregate_failures do
          expect(err).to include('not running')
          expect(st.exitstatus).to eq(0)
        end
      end
    end

    describe 'start' do
      let(:dir) { Dir.mktmpdir }
      let(:server_cmd) { ->(*args) { Open3.capture3(RbConfig.ruby, exe, 'server', *args, chdir: dir) } }

      after do
        server_cmd.call('stop')
        FileUtils.remove_entry(dir)
      end

      it 'starts the server and reports success' do
        _out, err, st = server_cmd.call('start')
        aggregate_failures do
          expect(err).to include('started')
          expect(st.exitstatus).to eq(0)
        end
      end

      it 'makes the server accessible for status' do
        _out, err, st = server_cmd.call('start') && server_cmd.call('status')
        aggregate_failures do
          expect(err).to include('running')
          expect(st.exitstatus).to eq(0)
        end
      end

      it 'reports already running on second start' do
        _out, err, st = [server_cmd.call('start'), server_cmd.call('start')][1]
        aggregate_failures do
          expect(err).to include('already running')
          expect(st.exitstatus).to eq(0)
        end
      end
    end

    describe 'stop' do
      let(:dir) { Dir.mktmpdir }
      let(:server_cmd) { ->(*args) { Open3.capture3(RbConfig.ruby, exe, 'server', *args, chdir: dir) } }

      after do
        server_cmd.call('stop')
        FileUtils.remove_entry(dir)
      end

      it 'reports not running when no server' do
        _out, err, st = server_cmd.call('stop')
        aggregate_failures do
          expect(err).to include('not running')
          expect(st.exitstatus).to eq(0)
        end
      end

      it 'stops a running server' do
        _out, stop_err, stop_st = server_cmd.call('start') && server_cmd.call('stop')
        aggregate_failures do
          expect(stop_err).to include('stopped')
          expect(stop_st.exitstatus).to eq(0)
        end
      end
    end

    describe 'start/stop lifecycle' do
      let(:dir) { Dir.mktmpdir }
      let(:server_status) do
        _, err, = Open3.capture3(RbConfig.ruby, exe, 'server', 'status', chdir: dir)
        err
      end

      after do
        Open3.capture3(RbConfig.ruby, exe, 'server', 'stop', chdir: dir)
        FileUtils.remove_entry(dir)
      end

      it 'starts as not running' do
        expect(server_status).to include('not running')
      end

      it 'becomes running after start' do
        Open3.capture3(RbConfig.ruby, exe, 'server', 'start', chdir: dir)
        expect(server_status).to include('running')
      end

      it 'returns to not running after stop' do
        Open3.capture3(RbConfig.ruby, exe, 'server', 'start', chdir: dir)
        Open3.capture3(RbConfig.ruby, exe, 'server', 'stop', chdir: dir)
        sleep 0.2
        expect(server_status).to include('not running')
      end
    end
  end

  describe '--server flag' do
    let(:dir) { Dir.mktmpdir }
    let(:file) { "#{dir}/#{SecureRandom.hex(8)}.rb" }
    let(:server_cmd) { ->(*args) { Open3.capture3(RbConfig.ruby, exe, 'server', *args, chdir: dir) } }

    before do
      File.write(file, <<~RUBY)
        def hello
          puts 'world'
        end
      RUBY
      _, start_err, start_st = server_cmd.call('start')
      raise "Failed to start server: #{start_err}" unless start_st&.exitstatus == 0
    end

    after do
      server_cmd.call('stop')
      FileUtils.remove_entry(dir)
    end

    it 'returns findings from the server' do
      out, _err, st = Open3.capture3(RbConfig.ruby, exe, '--server', 'check', file, chdir: dir)
      aggregate_failures do
        expect(out).to include('Would update:')
        expect(st.exitstatus).to eq(1)
      end
    end

    context 'with --autocorrect' do
      it 'applies fixes via the server' do
        _out, _err, st = Open3.capture3(RbConfig.ruby, exe, '--server', '-a', file, chdir: dir)
        aggregate_failures do
          expect(st.exitstatus).to eq(0)
          expect(File.read(file)).to include('@return')
        end
      end
    end

    context 'with --quiet' do
      it 'does not print change details' do
        out, _err, _st = Open3.capture3(RbConfig.ruby, exe, '--server', '--quiet', 'check', file, chdir: dir)
        aggregate_failures do
          expect(out).to include('Would update:')
          expect(out).not_to include('missing docs')
        end
      end
    end
  end

  describe 'docscribe-client thin executable' do
    let(:dir) { Dir.mktmpdir }
    let(:thin_exe) { File.expand_path('exe/docscribe-client') }
    let(:file) { "#{dir}/test.rb" }

    before do
      File.write(file, <<~RUBY)
        def hello
          puts 'world'
        end
      RUBY
      Open3.capture3(RbConfig.ruby, exe, 'server', 'start', chdir: dir)
    end

    after do
      Open3.capture3(RbConfig.ruby, exe, 'server', 'stop', chdir: dir)
      FileUtils.remove_entry(dir)
    end

    it 'checks a file and returns JSON', :aggregate_failures do
      out, _, st = Open3.capture3(RbConfig.ruby, thin_exe, '--check', file, chdir: dir)
      result = JSON.parse(out)
      expect(result.dig('result', 'status')).to eq('fail')
      expect(st.exitstatus).to eq(0)
    end
  end
end
