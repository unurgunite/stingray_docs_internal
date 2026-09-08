# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Docscribe::InlineRewriter do
  describe 'aggressive mode (default)' do
    subject(:out) { inline(code, strategy: :aggressive) }

    let(:code) do
      <<~RUBY
        class Demo
          # Documentation
          #
          # @param [Object] name User full name
          # @param [Object] age Age in years
          # @return [String] greeting message
          def greet(name, age)
            "Hello, \#{name}"
          end
        end
      RUBY
    end

    it 'replaces param descriptions with static placeholder', :aggregate_failures do
      expect(out).to include(param_tag('name', 'Object'))
      expect(out).not_to include('User full name')
    end

    it 'replaces return tag with no description' do
      expect(out).to include('# @return [String]')
    end
  end

  describe 'aggressive mode with keep_descriptions: true' do
    subject(:out) { inline(code, strategy: :aggressive, config: config) }

    let(:config) { Docscribe::Config.new('keep_descriptions' => true) }

    let(:code) do
      <<~RUBY
        class Demo
          # Documentation
          #
          # @param [Object] name User full name
          # @param [Object] age Age in years
          # @return [String] greeting message
          def greet(name, age)
            "Hello, \#{name}"
          end
        end
      RUBY
    end

    it 'preserves existing @param descriptions', :aggregate_failures do
      expect(out).to include('User full name')
      expect(out).to include('Age in years')
    end

    it 'preserves existing @return description' do
      expect(out).to include('# @return [String] greeting message')
    end

    it 'does not duplicate param lines' do
      count = out.scan(/@param/).length
      expect(count).to eq(2)
    end
  end

  describe 'aggressive mode with keep_descriptions: true — partial' do
    subject(:out) { inline(code, strategy: :aggressive, config: config) }

    let(:config) { Docscribe::Config.new('keep_descriptions' => true) }

    let(:code) do
      <<~RUBY
        class Demo
          # Documentation
          #
          # @param [Object] name
          # @param [Object] age
          def greet(name, age)
            "Hello, \#{name}"
          end
        end
      RUBY
    end

    it 'inserts static placeholder when no description exists', :aggregate_failures do
      expect(out).to include(param_tag('name', 'Object'))
      expect(out).to include(param_tag('age', 'Object'))
    end
  end

  describe 'safe mode unaffected by keep_descriptions' do
    subject(:out) { inline(code, strategy: :safe, config: config) }

    let(:config) { Docscribe::Config.new('keep_descriptions' => true) }

    let(:code) do
      <<~RUBY
        class Demo
          # Existing doc
          #
          # @param [Object] name User full name
          def greet(name, age)
            "Hello, \#{name}"
          end
        end
      RUBY
    end

    it 'preserves existing param descriptions' do
      expect(out).to include('User full name')
    end

    it 'appends placeholder for new params' do
      expect(out).to include(param_tag('age', 'Object'))
    end
  end

  describe 'aggressive mode keep_descriptions: true — @return only' do
    subject(:out) { inline(code, strategy: :aggressive, config: config) }

    let(:config) { Docscribe::Config.new('keep_descriptions' => true) }

    let(:code) do
      <<~RUBY
        class Demo
          # Documentation
          #
          # @return [String] the formatted output
          def greet(name)
            "Hello, \#{name}"
          end
        end
      RUBY
    end

    it 'preserves @return description and generates @param', :aggregate_failures do
      expect(out).to include('# @return [String] the formatted output')
      expect(out).to include(param_tag('name', 'Object'))
    end
  end

  describe 'aggressive mode keep_descriptions: true — multi-line descriptions' do
    subject(:out) { inline(code, strategy: :aggressive, config: config) }

    let(:config) { Docscribe::Config.new('keep_descriptions' => true) }

    let(:code) do
      <<~RUBY
        class Demo
          # Process the input data
          #
          # This method handles normalization,
          # validation, and transformation.
          #
          # @param [String] name The users full name.
          #   Should not be empty.
          # @param [Integer] age The users age.
          # @return [String] The greeting message.
          #   May be personalized.
          def greet(name, age)
            "Hello, \#{name}"
          end
        end
      RUBY
    end

    it 'preserves multi-line @return description', :aggregate_failures do
      expect(out).to include('# @return [String] The greeting message.')
      expect(out).to include('#   May be personalized.')
    end

    it 'preserves multi-line @param description', :aggregate_failures do
      expect(out).to include('@param [Object] name The users full name.')
      expect(out).to include('#   Should not be empty.')
    end

    it 'preserves general multi-line description before tags', :aggregate_failures do
      expect(out).to include('# This method handles normalization,')
      expect(out).to include('# validation, and transformation.')
    end

    it 'does not accumulate on repeated runs', :aggregate_failures do
      twice = described_class.insert_comments(
        out, strategy: :aggressive, config: config
      )
      expect(twice).to eq(out)
    end
  end

  describe 'aggressive mode keep_descriptions: true — with RBS Tuple types' do
    subject(:out) do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, 'sig')
        FileUtils.mkdir_p(sig_dir)
        File.write(File.join(sig_dir, 'demo.rbs'), rbs)

        inline(
          code, strategy: :aggressive,
                config: Docscribe::Config.new(
                  'rbs' => { 'enabled' => true, 'sig_dirs' => [sig_dir] },
                  'keep_descriptions' => true
                )
        )
      end
    end

    before { skip_unless_rbs_available! }

    let(:rbs) do
      <<~RBS
        class Demo
          def greet: (::String name, ::Integer age) -> [::String, ::Integer]
        end
      RBS
    end

    let(:code) do
      <<~RUBY
        class Demo
          # Say hello
          #
          # @param [String] name The users name.
          # @return [Array] A tuple with greeting and count.
          def greet(name, age)
            ["Hello, \#{name}", age]
          end
        end
      RUBY
    end

    it 'formats Tuple type without brackets', :aggregate_failures do
      expect(out).to include('@return [(String, Integer)]')
      expect(out).not_to include('@return [[(String, Integer)]')
    end

    it 'preserves @param description' do
      expect(out).to include('The users name.')
    end

    it 'preserves general description' do
      expect(out).to include('# Say hello')
    end

    it 'does not accumulate brackets on repeated runs' do
      expect(idempotent_reinsert(out, rbs)).to eq(out)
    end
  end

  describe 'aggressive mode keep_descriptions: true — with nested Tuple types' do
    subject(:out) do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, 'sig')
        FileUtils.mkdir_p(sig_dir)
        File.write(File.join(sig_dir, 'demo.rbs'), rbs)

        inline(
          code, strategy: :aggressive,
                config: Docscribe::Config.new(
                  'rbs' => { 'enabled' => true, 'sig_dirs' => [sig_dir] },
                  'keep_descriptions' => true
                )
        )
      end
    end

    before { skip_unless_rbs_available! }

    let(:rbs) do
      <<~RBS
        class Demo
          def stats: (::String name) -> [::Integer, ::Array[::String]]
        end
      RBS
    end

    let(:code) do
      <<~RUBY
        class Demo
          # Collect stats
          #
          # @param [String] name The name.
          # @return [Array] stats
          def stats(name)
            [42, ["a", "b"]]
          end
        end
      RUBY
    end

    it 'formats nested Tuple with generics correctly', :aggregate_failures do
      expect(out).to include('@return [(Integer, Array<String>)]')
      expect(out).not_to include('[[')
    end

    it 'preserves @return description' do
      expect(out).to include('stats')
    end

    it 'is idempotent across runs' do
      expect(idempotent_reinsert(out, rbs)).to eq(out)
    end
  end

  describe 'via CLI' do
    subject(:result) { Open3.capture3('ruby', exe, '-Ak', path, chdir: dir) }

    let(:exe)  { File.expand_path('exe/docscribe') }
    let(:dir)  { Dir.mktmpdir }
    let(:path) { File.join(dir, 'foo.rb') }

    before do
      File.write(path, <<~RUBY)
        class Foo
          # Docs
          #
          # @param [Object] name User name
          # @return [String] result
          def bar(name)
            "hi, \#{name}"
          end
        end
      RUBY
    end

    after { FileUtils.remove_entry(dir) }

    it 'preserves descriptions with -Ak', :aggregate_failures do
      skip 'cannot suppress RBS fallback warning on Ruby 2.7' if RUBY_VERSION < '3.0'
      expect(result[2].exitstatus).to eq(0)
      content = File.read(path)
      expect(content).to include('User name')
      expect(content).to include('# @return [String] result')
    end
  end
end
