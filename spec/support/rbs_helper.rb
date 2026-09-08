# frozen_string_literal: true

module RbsHelper
  # Rewrite +code+ with Sorbet integration enabled.
  #
  # @param [String] code Ruby source to rewrite
  # @param [Symbol] strategy :safe or :aggressive
  # @param [Hash] config_overrides additional raw config keys merged on top
  # @return [String] rewritten source
  def inline_with_sorbet(code, strategy: :safe, config_overrides: {})
    skip_unless_sorbet_bridge_available!
    raw = { 'sorbet' => { 'enabled' => true } }.merge(config_overrides)
    inline(code, strategy: strategy, config: Docscribe::Config.new(**raw))
  end

  # Rewrite +code+ with both Sorbet RBI and optionally RBS signature files.
  #
  # Creates a temporary directory, writes the provided signature content to
  # files inside it, builds a config from those paths, and rewrites +code+.
  #
  # @param [String] code Ruby source to rewrite
  # @param [String] rbi RBI file content
  # @param [String, nil] rbs RBS file content (optional)
  # @param [Hash] dir_names directory names for RBI and sig
  # @param [Hash] config_overrides additional raw config keys merged on top
  # @return [String] rewritten source
  def inline_with_signature_files(code:, rbi:, rbs: nil, dir_names: { rbi: 'sorbet/rbi', sig: 'sig' },
                                  config_overrides: {})
    skip_unless_sorbet_bridge_available!
    Dir.mktmpdir do |dir|
      rbi_dir = File.join(dir, dir_names[:rbi])
      FileUtils.mkdir_p(rbi_dir)
      File.write(File.join(rbi_dir, 'demo.rbi'), rbi)
      raw = { 'sorbet' => { 'enabled' => true, 'rbi_dirs' => [rbi_dir] } }.merge(config_overrides)
      raw.merge!(rbs_config(dir, dir_names[:sig], rbs)) if rbs
      inline(code, config: Docscribe::Config.new(**raw))
    end
  end

  # Rewrite +code+ with RBS integration enabled.
  #
  # Creates a temporary directory, writes the provided RBS content to a file
  # inside it, builds a config from that path, and rewrites +code+.
  #
  # @param [String] code Ruby source to rewrite
  # @param [String] rbs RBS file content
  # @param [String] sig_dir_name relative path for the sig directory
  # @param [Hash] config additional config options merged into base
  # @return [String] rewritten source
  def inline_with_rbs(code:, rbs:, sig_dir_name: 'sig', config: {})
    skip_unless_rbs_available!

    Dir.mktmpdir do |dir|
      sig_dir = File.join(dir, sig_dir_name)
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, 'demo.rbs'), rbs)

      inline(
        code,
        config: Docscribe::Config.new(**config, 'rbs' => { 'enabled' => true, 'sig_dirs' => [sig_dir] })
      )
    end
  end

  # Runs docscribe in no-write mode and captures stdout for given source.
  #
  # @param [String] source Ruby source to check
  # @param [Array<String>] extra additional CLI arguments forwarded to run
  # @param [String] filename temporary file name
  # @return [String] captured stdout output
  def rbs_out(source, *extra, filename: 'test.rb')
    Dir.mktmpdir do |dir|
      path = File.join(dir, filename)
      File.write(path, source)
      capture_stdout { expect(described_class.run(['-n', path, *extra])).to eq(0) }
    end
  end

  # Creates a temporary directory with a Ruby file and yields its paths.
  #
  # @param [String] source Ruby source to write
  # @param [String] filename file name inside temp dir
  # @yieldparam [String] path path to the Ruby file
  # @yieldparam [String] dir temporary directory path
  # @return [Object] block result
  def with_rbs(source, filename: 'test.rb')
    Dir.mktmpdir do |dir|
      path = File.join(dir, filename)
      File.write(path, source)
      yield path, dir
    end
  end

  # Creates temp dir with Ruby file and existing RBS sig, yields paths.
  #
  # @param [String] rb_source Ruby source to write
  # @param [String] old_content existing RBS content for sig file
  # @param [String] sig_name signature file name
  # @yieldparam [String] path path to Ruby file
  # @yieldparam [String] dir temporary directory path
  # @yieldparam [String] sig_dir signature directory path
  # @return [Object] block result
  def with_existing_rbs(rb_source, old_content, sig_name: 'test.rbs')
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'test.rb')
      File.write(path, rb_source)
      FileUtils.mkdir_p("#{dir}/sig")
      File.write("#{dir}/sig/#{sig_name}", old_content)
      yield path, dir, "#{dir}/sig"
    end
  end

  private

  # Skips example unless RBS gem is available.
  #
  # Call at the top of any example that depends on RBS bridge parsing.
  #
  # @return [void]
  def skip_unless_rbs_available!
    require 'rbs'
  rescue LoadError
    skip 'RBS not available'
  end

  # Skips example unless RBS and RubyVM::AbstractSyntaxTree are available.
  #
  # Call at the top of any example that depends on Sorbet/RBS bridge parsing.
  #
  # @return [void]
  def skip_unless_sorbet_bridge_available!
    begin
      require 'rbs'
    rescue LoadError
      skip 'RBS not available'
    end

    skip 'RubyVM::AbstractSyntaxTree not available' unless defined?(RubyVM::AbstractSyntaxTree)
  end

  # Builds RBS config hash for a temporary sig directory.
  #
  # @param [String] dir temporary directory base path
  # @param [String] sig_dir_name relative sig directory name
  # @param [String] rbs_content RBS content to write
  # @return [Hash<String, Hash>] RBS config fragment with enabled sig_dirs
  def rbs_config(dir, sig_dir_name, rbs_content)
    sig_dir = File.join(dir, sig_dir_name)
    FileUtils.mkdir_p(sig_dir)
    File.write(File.join(sig_dir, 'demo.rbs'), rbs_content)
    { 'rbs' => { 'enabled' => true, 'sig_dirs' => [sig_dir] } }
  end
end
