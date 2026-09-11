# frozen_string_literal: true

RSpec.describe Docscribe::Plugin::Base::CollectorPlugin do
  after { Docscribe::Plugin::Registry.clear! }

  context 'when anchor_node is :def and plugin doc is tag-only' do
    subject(:out) { inline(code, config: conf, strategy: :safe) }

    let(:conf) do
      Docscribe::Config.new(
        'emit' => { 'include_default_message' => true },
        'doc' => { 'default_message' => 'PLUGIN DEFAULT.' }
      )
    end

    let(:code) do
      <<~RUBY
        class A
          def foo
            1
          end
        end
      RUBY
    end

    before do
      plugin = build_plugin(anchor_type: :def, doc: "# @return [Boolean]\n")
      Docscribe::Plugin::Registry.register(plugin)
    end

    it { expect(out).to include('# PLUGIN DEFAULT.') }
    it { expect(out).to include('# @return [Boolean]') }

    it 'has all parts present', :aggregate_failures do
      expect(out).to include('# PLUGIN DEFAULT.')
      expect(out).to include('# @return [Boolean]')
      expect(out).to include("def foo\n")
    end

    it 'orders default message before tag before def', :aggregate_failures do
      expect(out.index('# PLUGIN DEFAULT.')).to be < out.index('# @return [Boolean]')
      expect(out.index('# @return [Boolean]')).to be < out.index("def foo\n")
    end
  end

  context 'when include_default_message is false' do
    subject(:out) { inline(code, config: conf, strategy: :safe) }

    let(:conf) do
      Docscribe::Config.new(
        'emit' => { 'include_default_message' => false },
        'doc' => { 'default_message' => 'PLUGIN DEFAULT.' }
      )
    end

    let(:code) do
      <<~RUBY
        class A
          def foo
            1
          end
        end
      RUBY
    end

    before do
      plugin = build_plugin(anchor_type: :def, doc: "# @return [Boolean]\n")
      Docscribe::Plugin::Registry.register(plugin)
    end

    it 'does not prepend default message', :aggregate_failures do
      expect(out).not_to include('# PLUGIN DEFAULT.')
      expect(out).to include('# @return [Boolean]')
    end
  end

  context 'when plugin doc already contains prose' do
    subject(:out) { inline(code, config: conf, strategy: :safe) }

    let(:conf) do
      Docscribe::Config.new(
        'emit' => { 'include_default_message' => true },
        'doc' => { 'default_message' => 'PLUGIN DEFAULT.' }
      )
    end

    let(:code) do
      <<~RUBY
        class A
          def foo
            1
          end
        end
      RUBY
    end

    before do
      plugin = build_plugin(
        anchor_type: :def,
        doc: "# Custom prose line.\n# @return [Boolean]\n"
      )
      Docscribe::Plugin::Registry.register(plugin)
    end

    it 'does not prepend default message when plugin doc has prose', :aggregate_failures do
      expect(out).to include('# Custom prose line.')
      expect(out).to include('# @return [Boolean]')
      expect(out).not_to include('# PLUGIN DEFAULT.')
    end
  end

  context 'when anchor_node is :defs (class method)' do
    subject(:out) { inline(code, config: conf, strategy: :safe) }

    let(:conf) do
      Docscribe::Config.new(
        'emit' => { 'include_default_message' => true },
        'doc' => { 'default_message' => 'PLUGIN DEFAULT.' }
      )
    end

    let(:code) do
      <<~RUBY
        class A
          def self.foo
            1
          end
        end
      RUBY
    end

    before do
      plugin = build_plugin(anchor_type: :defs, doc: "# @return [Boolean]\n")
      Docscribe::Plugin::Registry.register(plugin)
    end

    it 'prepends default message for tag-only docs on :defs as well', :aggregate_failures do
      expect(out).to include('# PLUGIN DEFAULT.')
      expect(out).to include('# @return [Boolean]')
      expect(out).to include('def self.foo')
    end
  end

  context 'when anchor_node is not a method (:send)' do
    subject(:out) { inline(code, config: conf, strategy: :safe) }

    let(:conf) do
      Docscribe::Config.new(
        'emit' => { 'include_default_message' => true },
        'doc' => { 'default_message' => 'PLUGIN DEFAULT.' }
      )
    end

    let(:code) do
      <<~RUBY
        class A
          has_many :posts
        end
      RUBY
    end

    before do
      plugin = build_plugin(anchor_type: :send, doc: "# @return [Boolean]\n")
      Docscribe::Plugin::Registry.register(plugin)
    end

    it 'does not prepend default message for non-def anchors', :aggregate_failures do
      expect(out).to include('# @return [Boolean]')
      expect(out).not_to include('# PLUGIN DEFAULT.')
    end
  end

  context 'when plugin doc ends with whitespace-only lines' do
    subject(:out) { inline(code, config: conf, strategy: :safe) }

    let(:conf) do
      Docscribe::Config.new(
        'emit' => { 'include_default_message' => false }
      )
    end

    let(:code) do
      <<~RUBY
        class A
          def foo
            1
          end
        end
      RUBY
    end

    before do
      plugin = build_plugin(anchor_type: :def, doc: "# @return [Boolean]\n\n\n")
      Docscribe::Plugin::Registry.register(plugin)
    end

    it 'trims trailing whitespace-only lines (no extra empty lines before def)' do
      expect(out).to include("# @return [Boolean]\n  def foo")
    end
  end
end
