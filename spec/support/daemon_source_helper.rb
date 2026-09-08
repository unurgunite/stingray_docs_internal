# frozen_string_literal: true

module DaemonSourceHelper
  # Helpers for daemon source propagation (from daemon_source_comprehensive_spec).

  def rewrite_for_content(content)
    Dir.mktmpdir do |tmp_dir|
      path = File.join(tmp_dir, 'a.rb')
      File.write(path, content)
      daemon.send(:apply_cli_overrides, validate_overrides)
      daemon.send(:run_rewrite, path, :safe)
    end
  end

  def syntax_source(content)
    Dir.mktmpdir do |tmp_dir|
      path = File.join(tmp_dir, 'b.rb')
      File.write(path, content)
      daemon.send(:apply_cli_overrides, validate_overrides)
      trigger_check(path)
      fetch_syntax(path)
    end
  end

  def trigger_check(path)
    client.check(file: path)
    send_raw_request(socket_path, 'check', { 'file' => path })
  end

  def fetch_syntax(path)
    _source, result = daemon.send(:rewrite_file, path, :safe)
    result[:changes].first[:source]
  end

  def mixed_batch_results(first_content, second_content)
    Dir.mktmpdir do |tmp_dir|
      first = File.join(tmp_dir, 'a.rb')
      second = File.join(tmp_dir, 'b.rb')
      File.write(first, first_content)
      File.write(second, second_content)
      run_mixed(first, second)
    end
  end

  def run_mixed(first_path, second_path)
    daemon.send(:apply_cli_overrides, validate_overrides)
    first = daemon.send(:run_rewrite, first_path, :safe)
    second = daemon.send(:run_rewrite, second_path, :safe)
    batch = [first_path, second_path].map { |path| daemon.send(:run_rewrite, path, :safe) }
    extract_mixed(first, second, batch)
  end

  def extract_mixed(first, second, batch)
    [
      source_for(first, 'updated_return'),
      source_for(second, 'invalid_type'),
      batch.size,
      source_for(batch[0], 'updated_return'),
      source_for(batch[1], 'invalid_type')
    ]
  end

  def source_for(result, type)
    result['changes'].find { |change| change['type'].to_s == type }['source']
  end

  def rbs_daemon_source
    Dir.mktmpdir do |tmp_dir|
      Dir.chdir(tmp_dir) do
        FileUtils.mkdir_p('sig')
        File.write('sig/foo.rbs', rbs_signature)
        File.write('foo.rb', ruby_source)
        run_rbs_daemon(tmp_dir)
      end
    end
  end

  def run_rbs_daemon(tmp_dir)
    second_daemon = described_class.new(socket_path: "#{tmp_dir}/rbs2.sock", idle_timeout: 60)
    second_daemon.send(:load_dependencies)
    second_daemon.send(:apply_cli_overrides, rbs_overrides)
    _source, result = second_daemon.send(:rewrite_file, File.join(tmp_dir, 'foo.rb'), :safe)
    second_daemon.instance_variable_get(:@file_cache).clear
    result[:changes].first[:source]
  end

  def rbs_overrides
    { 'validate_types' => true, 'rbs' => true, 'sig_dirs' => ['sig'], 'include' => [], 'exclude' => [], 'include_file' => [], 'exclude_file' => [], 'rbi_dirs' => [], 'no_boilerplate' => true }
  end

  def param_change_with_rbs(code, rbs_content)
    result = rewrite_with_rbs(code, rbs_content)
    result[:changes].find { |change| change[:type] == :updated_param }
  end

  def rewrite_with_rbs(code, rbs_content)
    Dir.mktmpdir do |tmp_dir|
      sig_dir = File.join(tmp_dir, 'sig')
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, 'foo.rbs'), rbs_content)
      cfg = Docscribe::Config.new('validate_types' => true, 'rbs' => { 'enabled' => true, 'sig_dirs' => [sig_dir] })
      described_class.rewrite_with_report(code, strategy: :safe, config: cfg, file: 'test.rb')
    end
  end
end
