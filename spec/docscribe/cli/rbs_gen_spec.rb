# frozen_string_literal: true

require 'tmpdir'
require 'docscribe/cli/rbs_gen'

RSpec.describe Docscribe::CLI::RbsGen do
  describe '.run' do
    it 'shows error when no files found' do
      aggregate_failures do
        err = capture_stderr { expect(described_class.run(%w[--dry-run nonexistent.rb])).to eq(2) }
        expect(err).to include('No files found')
      end
    end

    it 'generates RBS for a file with YARD docs' do
      out = rbs_out("# @param [String] name\n# @return [Integer]\ndef process(name)\n  name.length\nend\n")
      expect(out).to include('def process: (String name) -> Integer')
    end

    it 'generates RBS for file without YARD docs' do
      out = rbs_out("def foo\n  :bar\nend\n")
      expect(out).to include('def foo: () -> untyped')
    end

    it 'handles class methods via self.' do
      out = rbs_out("class Foo\n  # @return [String]\n  def self.bar\n    'bar'\n  end\nend\n")
      expect(out).to include('def self.bar: () -> String')
    end

    it 'handles class << self' do
      out = rbs_out("class Foo\n  class << self\n    # @return [String]\n    " \
                    "def bar\n      'bar'\n    end\n  end\nend\n")
      expect(out).to include('def self.bar: () -> String')
    end

    it 'handles module_function' do
      out = rbs_out("module Foo\n  # @return [String]\n  def bar\n    'bar'\n  end\n  module_function :bar\nend\n")
      expect(out).to include('def bar: () -> String')
    end

    it 'generates RBS for a directory' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a.rb", "# @return [Integer]\ndef a; 1; end\n")
        expect(capture_stdout { described_class.run(['-n', dir]) }).to include('def a: () -> Integer')
      end
    end

    it 'converts YARD types to RBS' do
      source = "# @param [Array<String>] items\n# @param [Hash{Symbol => Integer}] counts\n" \
               "# @param [Boolean] enabled\n# @return [Array<Integer>]\ndef transform(items, counts, enabled)\n  " \
               "[]\nend\n"
      expect(rbs_out(source)).to include('Array[String]', 'bool enabled', '-> Array[Integer]')
    end

    it 'converts @option to keyword args' do
      out = rbs_out(
        "# @param [Hash] opts options hash\n# @option opts [Boolean] :verbose enable verbose\n" \
        "# @option opts [String] :format output format\n# @return [void]\ndef run(opts)\nend\n"
      )
      expect(out).to include('?bool verbose', '?String format')
    end

    it 'writes files when not in dry-run mode', :aggregate_failures do
      with_rbs("# @return [String]\ndef foo; 'foo'; end\n") do |rb, dir|
        FileUtils.mkdir_p(File.join(dir, 'sig'))
        capture_stdout { expect(described_class.run(['-o', File.join(dir, 'sig'), rb])).to eq(0) }
        expect(File.read(File.join(dir, 'sig', 'test.rbs'))).to include('def foo: () -> String')
      end
    end

    it 'skips existing files without --force', :aggregate_failures do
      with_existing_rbs("# @return [String]\ndef foo; end\n", 'old content') do |rb, _dir, sig_dir|
        _code, _out, err = capture_stdout_stderr { described_class.run(['-o', sig_dir, rb]) }
        expect(err).to include('Skipping')
        expect(File.read("#{sig_dir}/test.rbs")).to eq('old content')
      end
    end

    it 'overwrites with --force' do
      with_existing_rbs("# @return [String]\ndef foo; end\n", 'old content') do |rb, _dir, sig_dir|
        _code, _out, _err = capture_stdout_stderr { described_class.run(['-o', sig_dir, '-f', rb]) }
        expect(File.read("#{sig_dir}/test.rbs")).to include('def foo: () -> String')
      end
    end

    it 'handles files gracefully' do
      expect { rbs_out("def foo(\n", filename: 'broken.rb') }.not_to raise_error
    end

    it 'handles empty file' do
      out = rbs_out('')
      expect(out).to be_empty
    end
  end

  describe 'parse_yard_tags' do
    it 'parses @param [Type] name format' do
      tags = described_class.send(:parse_yard_tags, ['# @param [String] name the name'])
      expect(tags.params).to contain_exactly(have_attributes(name: 'name', type: 'String'))
    end

    it 'parses @param name [Type] format' do
      tags = described_class.send(:parse_yard_tags, ['# @param name [String] the name'])
      expect(tags.params).to contain_exactly(have_attributes(name: 'name', type: 'String'))
    end

    it 'parses @return' do
      tags = described_class.send(:parse_yard_tags, ['# @return [Integer] the count'])
      expect(tags.return_type).to eq('Integer')
    end

    it 'returns nil return_type when absent' do
      tags = described_class.send(:parse_yard_tags, ['# @param [String] name'])
      expect(tags.return_type).to be_nil
    end

    it 'parses @option' do
      tags = described_class.send(:parse_yard_tags, ['# @option options [Boolean] :verbose enable verbose'])
      expect(tags.options).to contain_exactly(have_attributes(name: 'verbose', type: 'Boolean'))
    end

    it 'strips leading colon from option name' do
      tags = described_class.send(:parse_yard_tags, ['# @option opts [String] :name the name'])
      expect(tags.options.first.name).to eq('name')
    end
  end

  describe 'type_to_rbs' do
    it 'converts Array<String>' do
      expect(described_class.send(:type_to_rbs, 'Array<String>')).to eq('Array[String]')
    end

    it 'converts Boolean to bool' do
      expect(described_class.send(:type_to_rbs, 'Boolean')).to eq('bool')
    end

    it 'converts Hash{Symbol => Integer}' do
      expect(described_class.send(:type_to_rbs, 'Hash{Symbol => Integer}')).to eq('Hash[Symbol, Integer]')
    end

    it 'converts Object to untyped' do
      expect(described_class.send(:type_to_rbs, 'Object')).to eq('untyped')
    end
  end

  describe 'find_yard_block' do
    it 'finds the comment block before a method' do
      src_lines = ["# comment 1\n", "# comment 2\n", "def foo\n"]
      comment_map = { 1 => '# comment 1', 2 => '# comment 2' }
      block = described_class.send(:find_yard_block, 3, comment_map, src_lines)
      expect(block).to eq(['# comment 1', '# comment 2'])
    end

    it 'returns empty when no comments before method' do
      src_lines = ["x = 1\n", "def foo\n"]
      comment_map = {}
      block = described_class.send(:find_yard_block, 2, comment_map, src_lines)
      expect(block).to be_empty
    end

    it 'stops at blank lines' do
      src_lines = ["# comment\n", "\n", "def foo\n"]
      comment_map = { 1 => '# comment' }
      block = described_class.send(:find_yard_block, 3, comment_map, src_lines)
      expect(block).to be_empty
    end
  end

  describe 'format_method_sig' do
    it 'formats instance method' do
      tags = t(params: [], return_type: 'String', options: [])
      md = d(name: 'foo', scope: :instance, container: nil, file: 'x.rb', line: 1, yard_tags: tags)
      expect(described_class.send(:format_method_sig, md)).to eq('def foo: () -> String')
    end

    it 'formats class method with self.' do
      tags = t(params: [], return_type: 'Integer', options: [])
      md = d(name: 'bar', scope: :class, container: nil, file: 'x.rb', line: 1, yard_tags: tags)
      expect(described_class.send(:format_method_sig, md)).to eq('def self.bar: () -> Integer')
    end

    it 'includes params' do
      tags = t(params: [p(name: 'name', type: 'String')], return_type: 'void', options: [])
      md = d(name: 'process', scope: :instance, container: nil, file: 'x.rb', line: 1, yard_tags: tags)
      expect(described_class.send(:format_method_sig, md)).to eq('def process: (String name) -> void')
    end

    it 'includes options as optional keyword args' do
      tags = t(params: [], return_type: 'void', options: [p(name: 'verbose', type: 'Boolean')])
      md = d(name: 'run', scope: :instance, container: nil, file: 'x.rb', line: 1, yard_tags: tags)
      expect(described_class.send(:format_method_sig, md)).to eq('def run: (?bool verbose) -> void')
    end
  end

  describe 'build_rbs_content' do
    let(:defs) do
      [d(name: 'foo', container: 'Foo', line: 1, scope: :instance, file: 'x.rb', yard_tags: nil),
       d(name: 'bar', container: 'Foo', line: 2, scope: :instance, file: 'x.rb', yard_tags: nil),
       d(name: 'baz', container: nil, line: 3, scope: :instance, file: 'x.rb', yard_tags: nil)]
    end

    it 'groups methods by container' do
      content = described_class.send(:build_rbs_content, defs)
      expect(content).to include('class Foo', '  def foo: () -> untyped',
                                 '  def bar: () -> untyped', 'end', 'def baz: () -> untyped')
    end
  end
end
