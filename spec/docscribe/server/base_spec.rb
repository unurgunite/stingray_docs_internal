# frozen_string_literal: true

require 'tmpdir'
require 'docscribe/server'

RSpec.describe Docscribe::Server do
  describe '.socket_path' do
    it 'returns a path under tmpdir' do
      expect(described_class.socket_path).to match(%r{\A(?:#{Regexp.escape(Dir.tmpdir)}|/tmp)/docscribe-})
    end

    it 'includes an MD5 of the working directory' do
      seed = +Dir.pwd
      seed << ":#{described_class.send(:env_hash)}"
      hash_segment = Digest::MD5.hexdigest(seed)
      expect(described_class.socket_path).to include(hash_segment)
    end

    describe 'with config_path' do
      around { |ex| Dir.mktmpdir { |t| Dir.chdir(t, &ex) } }

      it 'resolves relative path to absolute before hashing' do
        rel = described_class.socket_path('some.yml')
        abs = described_class.socket_path("#{Dir.pwd}/some.yml")
        expect(rel).to eq(abs)
      end

      it 'includes mtime as float' do
        File.write('cfg.yml', '')
        expect(described_class.socket_path('cfg.yml')).to match(/\.sock\z/)
      end
    end
  end

  describe '.wait_for_ready' do
    it 'returns when server becomes ready' do
      allow(described_class).to receive(:running?).and_return(true)
      expect { described_class.wait_for_ready(timeout: 5) }.not_to raise_error
    end

    it 'raises on timeout when raise_on_timeout is true' do
      allow(described_class).to receive(:running?).and_return(false)

      expect do
        described_class.wait_for_ready(timeout: 0.01, raise_on_timeout: true)
      end.to raise_error(RuntimeError, 'Docscribe: server failed to start')
    end

    it 'does not raise on timeout when raise_on_timeout is false' do
      allow(described_class).to receive(:running?).and_return(false)

      expect do
        described_class.wait_for_ready(timeout: 0.01, raise_on_timeout: false)
      end.not_to raise_error
    end
  end

  describe '.process_alive?' do
    it 'returns true when process exists' do
      expect(described_class.send(:process_alive?, Process.pid)).to be true
    end

    it 'returns false when process is gone' do
      pid = spawn('true')
      Process.wait(pid)
      expect(described_class.send(:process_alive?, pid)).to be false
    end
  end

  describe '.ensure_running!' do
    around { |ex| Dir.mktmpdir { |t| Dir.chdir(t, &ex) } }

    after { described_class.clean_socket_files(nil) }

    before do
      allow(described_class).to receive_messages(running?: false, wait_for_ready: false)
      allow(Process).to receive(:fork).and_return(12_345)
      allow(Process).to receive(:detach)
    end

    it 'returns early when server is already running' do
      allow(described_class).to receive(:running?).and_return(true)
      described_class.ensure_running!
      expect(Process).not_to have_received(:fork)
    end

    it 'raises when fork is unavailable' do
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
      expect { described_class.ensure_running! }.to raise_error(/JRuby/)
    end

    it 'calls fork' do
      described_class.ensure_running!
      expect(Process).to have_received(:fork)
    end

    it 'calls wait_for_ready after fork' do
      described_class.ensure_running!
      expect(described_class).to have_received(:wait_for_ready).at_least(:once)
    end
  end

  describe '.handle_stale_socket?' do
    let(:dir) { Dir.mktmpdir }
    let(:sock) { "#{dir}/test.sock" }
    let(:pidfile) { "#{dir}/test.pid" }
    let(:setup_alive) do
      allow(described_class).to receive(:read_pid).and_return(Process.pid)
      allow(described_class).to receive_messages(socket_path: sock, pid_path: pidfile)
      File.write(sock, '')
    end
    let(:setup_dead) do
      pid = spawn('true')
      Process.wait(pid)
      allow(described_class).to receive(:read_pid).and_return(pid)
      allow(described_class).to receive_messages(socket_path: sock, pid_path: pidfile)
      pid
    end

    after { FileUtils.rm_rf(dir) }

    it 'returns false when PID is alive' do
      setup_alive
      expect(described_class.send(:handle_stale_socket?, nil)).to be false
    end

    it 'does not clean up socket when PID is alive' do
      setup_alive
      described_class.send(:handle_stale_socket?, nil)
      expect(File.exist?(sock)).to be true
    end

    it 'cleans up socket when PID is dead' do
      _pid = setup_dead
      File.write(sock, '')
      described_class.send(:handle_stale_socket?, nil)
      expect(File.exist?(sock)).to be false
    end

    it 'cleans up pidfile when PID is dead' do
      pid = setup_dead
      File.write(pidfile, pid.to_s)
      described_class.send(:handle_stale_socket?, nil)
      expect(File.exist?(pidfile)).to be false
    end
  end

  describe '.running?' do
    let(:dir) { Dir.mktmpdir }
    let(:sock) { "#{dir}/test.sock" }

    after { FileUtils.rm_rf(dir) }

    it 'returns false when socket does not exist' do
      allow(described_class).to receive(:socket_path).and_return("#{Dir.tmpdir}/nonexistent.sock")
      expect(described_class.running?).to be false
    end

    it 'returns false when socket file is stale (not a real socket)' do
      allow(described_class).to receive_messages(socket_path: sock, pid_path: "#{dir}/test.pid")
      File.write(sock, '')
      expect(described_class.running?).to be false
    end

    it 'cleans up stale socket file' do
      allow(described_class).to receive_messages(socket_path: sock, pid_path: "#{dir}/test.pid")
      File.write(sock, '')
      described_class.running?
      expect(File.exist?(sock)).to be false
    end
  end

  # rubocop:disable RSpec/IdenticalEqualityAssertion
  describe '.env_hash' do
    around { |ex| Dir.mktmpdir { |t| Dir.chdir(t, &ex) } }

    it 'returns consistent hash when no sig files' do
      expect(described_class.send(:env_hash)).to eq(described_class.send(:env_hash))
    end

    context 'when sig file content changes' do
      before do
        FileUtils.mkdir_p('sig')
        File.write('sig/a.rbs', 'class A; def foo: () -> Integer; end')
      end

      let(:initial_hash) { described_class.send(:env_hash) }
      let(:updated_hash) do
        sleep 0.02
        File.write('sig/a.rbs', 'class A; def foo: () -> String; end')
        described_class.send(:env_hash)
      end

      it 'changes hash' do
        expect(initial_hash).not_to eq(updated_hash)
      end
    end

    context 'when new sig file is added' do
      before { FileUtils.mkdir_p('sig') }

      let(:initial_hash) { described_class.send(:env_hash) }
      let(:updated_hash) do
        File.write('sig/b.rbs', 'class B; end')
        described_class.send(:env_hash)
      end

      it 'changes hash' do
        expect(initial_hash).not_to eq(updated_hash)
      end
    end

    context 'when sig file is removed' do
      before do
        FileUtils.mkdir_p('sig')
        File.write('sig/c.rbs', 'class C; end')
      end

      let(:initial_hash) { described_class.send(:env_hash) }
      let(:after_removal_hash) do
        FileUtils.rm('sig/c.rbs')
        described_class.send(:env_hash)
      end

      it 'changes hash' do
        expect(initial_hash).not_to eq(after_removal_hash)
      end
    end

    context 'with docscribe.yml' do
      let(:initial_hash) { described_class.send(:env_hash) }
      let(:with_file_hash) do
        File.write('docscribe.yml', 'rbs: {enabled: true}')
        described_class.send(:env_hash)
      end

      after { FileUtils.rm_f('docscribe.yml') }

      it 'changes when docscribe.yml added' do
        expect(initial_hash).not_to eq(with_file_hash)
      end

      it 'restores after removal' do
        File.write('docscribe.yml', 'rbs: {enabled: true}')
        with_file_hash
        FileUtils.rm('docscribe.yml')
        expect(described_class.send(:env_hash)).to eq(initial_hash)
      end
    end
  end

  describe '.sig_hash' do
    around { |ex| Dir.mktmpdir { |t| Dir.chdir(t, &ex) } }

    context 'when sig file mtime changes' do
      before do
        FileUtils.mkdir_p('sig')
        File.write('sig/x.rbs', 'class X; end')
      end

      let(:initial_hash) { described_class.sig_hash }
      let(:updated_hash) do
        sleep 0.02
        File.write('sig/x.rbs', 'class X; def bar: () -> String; end')
        described_class.sig_hash
      end

      it 'changes hash' do
        expect(initial_hash).not_to eq(updated_hash)
      end
    end

    it 'is stable without changes' do
      expect(described_class.sig_hash).to eq(described_class.sig_hash)
    end

    context 'when sig file count changes' do
      before { FileUtils.mkdir_p('sig') }

      let(:initial_hash) { described_class.sig_hash }
      let(:updated_hash) do
        File.write('sig/y.rbs', 'class Y; end')
        described_class.sig_hash
      end

      it 'changes hash' do
        expect(initial_hash).not_to eq(updated_hash)
      end
    end
  end

  describe '.socket_path with sig and docscribe.yml' do
    around { |ex| Dir.mktmpdir { |t| Dir.chdir(t, &ex) } }

    context 'when sig file changes' do
      before do
        FileUtils.mkdir_p('sig')
        File.write('sig/a.rbs', 'class A; end')
      end

      let(:initial_path) { described_class.socket_path }
      let(:updated_path) do
        sleep 0.02
        File.write('sig/a.rbs', 'class A; def foo: () -> Integer; end')
        described_class.socket_path
      end

      it 'changes path' do
        expect(initial_path).not_to eq(updated_path)
      end
    end

    context 'when docscribe.yml changes' do
      let(:initial_path) { described_class.socket_path }
      let(:updated_path) do
        File.write('docscribe.yml', 'rbs: {enabled: false}')
        described_class.socket_path
      end

      after { FileUtils.rm_f('docscribe.yml') }

      it 'changes path' do
        expect(initial_path).not_to eq(updated_path)
      end
    end
  end
  # rubocop:enable RSpec/IdenticalEqualityAssertion
end
