# frozen_string_literal: true

require 'docscribe/server'
require 'docscribe/cli/update_types'
require 'fileutils'
require 'tmpdir'
require 'json'

RSpec.describe Docscribe::Server::Daemon do
  let!(:socket_path) { "#{Dir.mktmpdir}/ds-source.sock" }
  let!(:daemon) { described_class.new(socket_path: socket_path, idle_timeout: 60) }
  let!(:daemon_thread) { Thread.new { daemon.start } }
  let(:client) { Docscribe::Server::Client.new(socket_path) }

  let(:validate_overrides) do
    {
      'validate_types' => true, 'include' => [], 'exclude' => [],
      'include_file' => [], 'exclude_file' => [], 'sig_dirs' => [],
      'rbi_dirs' => [], 'no_boilerplate' => true
    }
  end

  before do
    sleep 0.3 until File.exist?(socket_path)
  end

  after do
    suppress_error { Docscribe::Server::Client.new(socket_path).shutdown }
    suppress_error { daemon_thread.join(3) }
    FileUtils.remove_entry(File.dirname(socket_path))
  end

  describe 'file param for update_types (441)' do
    context 'when request provides file param' do
      subject(:response) { send_raw_request(socket_path, 'update_types', { 'file' => 'myfile.rb' }) }

      before do
        allow(Docscribe::CLI::UpdateTypes).to receive(:run).with(['myfile.rb']).and_return(0)
      end

      it 'respects file param via raw request', :aggregate_failures do
        expect(response['result']['dir']).to eq('myfile.rb')
        expect(Docscribe::CLI::UpdateTypes).to have_received(:run).with(['myfile.rb'])
      end
    end

    describe '#update_types_dir priority' do
      it 'prefers file over dir and directory', :aggregate_failures do
        expect(daemon.send(:update_types_dir, { 'file' => 'a.rb', 'dir' => 'b', 'directory' => 'c' })).to eq('a.rb')
        expect(daemon.send(:update_types_dir, { 'dir' => 'b', 'directory' => 'c' })).to eq('b')
        expect(daemon.send(:update_types_dir, { 'directory' => 'c' })).to eq('c')
        expect(daemon.send(:update_types_dir, {})).to eq('.')
      end
    end

    context 'when file cache is populated' do
      before do
        daemon.instance_variable_get(:@file_cache)[%w[test.rb safe]] = { mtime: Time.now, sig_hash: '0', src: '', result: {} }
        allow(Docscribe::CLI::UpdateTypes).to receive(:run).and_return(0)
      end

      it 'clears file cache after update_types even with file target' do
        client.update_types(dir: 'somefile.rb')
        expect(daemon.instance_variable_get(:@file_cache)).to be_empty
      end
    end
  end

  describe 'source field propagation via daemon' do
    context 'when YARD return mismatches inferred type' do
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

      it 'run_rewrite stringifies source field - source' do
        result = rewrite_for_content(ruby_source)
        expect(result['changes'].first['source']).to eq('infer')
      end

      it 'run_rewrite stringifies source field - type' do
        result = rewrite_for_content(ruby_source)
        expect(result['changes'].first['type'].to_s).to eq('updated_return')
      end
    end

    context 'when YARD contains invalid syntax' do
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

      it 'check request returns changes with source syntax' do
        source = syntax_source(ruby_source)
        expect(source).to eq('syntax')
      end
    end

    context 'when handling mixed source types in batch' do
      let(:first_file_content) { "class A\n# @return [Integer]\ndef foo\n\"hi\"\nend\nend\n" }
      let(:second_file_content) { "class B\n# @return [Sym bol]\ndef bar\n:x\nend\nend\n" }

      it 'handles check_batch first pass', :aggregate_failures do
        first_src, second_src, = mixed_batch_results(first_file_content, second_file_content)
        expect(first_src).to eq('infer')
        expect(second_src).to eq('syntax')
      end

      it 'handles check_batch batch pass', :aggregate_failures do
        _, _, size, batch_first, batch_second = mixed_batch_results(first_file_content, second_file_content)
        expect(size).to eq(2)
        expect(batch_first).to eq('infer')
        expect(batch_second).to eq('syntax')
      end
    end
  end

  describe 'RBS source via daemon' do
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
    let(:rbs_signature) { "class Foo\n  def bar: () -> String\nend\n" }

    before { skip_unless_rbs_available! }

    it 'returns rbs source when sig provides different type' do
      source = rbs_daemon_source
      expect(source).to eq('rbs')
    end
  end
end
