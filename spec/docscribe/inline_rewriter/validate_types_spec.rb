# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'docscribe/inline_rewriter'
require 'docscribe/config'

RSpec.describe Docscribe::InlineRewriter do
  subject(:result) do
    described_class.rewrite_with_report(code, strategy: :safe, config: config, file: 'test.rb')
  end

  let(:config) { Docscribe::Config.new('validate_types' => validate) }
  let(:validate) { false }

  describe 'return mismatch' do
    context 'without validate_types' do
      let(:validate) { false }
      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end

      it 'does not report mismatch' do
        expect(result[:changes].any? { |c| c[:type] == :updated_return }).to be false
      end
    end

    context 'with validate_types' do
      let(:validate) { true }
      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end

      it 'reports updated_return', :aggregate_failures do
        updated = result[:changes].select { |c| c[:type] == :updated_return }
        expect(updated.size).to eq(1)
        expect(updated.first[:message]).to include('Integer').and include('String')
      end
    end

    context 'when inferred is Object fallback' do
      let(:validate) { true }
      let(:code) do
        <<~RUBY
          class Foo
            # @return [String]
            def bar
              unknown_method
            end
          end
        RUBY
      end

      it 'silences mismatch' do
        expect(result[:changes].any? { |c| c[:type] == :updated_return }).to be false
      end
    end
  end

  describe 'invalid syntax' do
    let(:code) do
      <<~RUBY
        class Foo
          # @return [Sym bol]
          def bar
            :x
          end
        end
      RUBY
    end

    it 'reports invalid_type even without validate_types' do
      expect(result[:changes].select { |c| c[:type] == :invalid_type }.size).to eq(1)
    end

    it 'provides corrected line for safe fix Sym bol -> Symbol', :aggregate_failures do
      expect(result[:output]).to include('@return [Symbol]')
      expect(result[:output]).not_to include('Sym bol')
    end
  end

  describe 'invalid syntax Objec3t' do
    let(:code) do
      <<~RUBY
        class Foo
          # @return [Objec3t]
          def bar
            Object.new
          end
        end
      RUBY
    end

    it 'provides corrected line for safe fix Objec3t -> Object', :aggregate_failures do
      expect(result[:output]).to include('@return [Object]')
      expect(result[:output]).not_to include('Objec3t')
    end
  end

  describe 'param mismatch' do
    let(:validate) { true }
    let(:code) do
      <<~RUBY
        class Foo
          # @param [String] x
          # @return [Object]
          def bar(x: 123)
            x
          end
        end
      RUBY
    end

    it 'reports updated_param', :aggregate_failures do
      updated = result[:changes].select { |c| c[:type] == :updated_param }
      expect(updated.size).to eq(1)
      expect(updated.first[:message]).to include('x')
    end
  end

  describe 'param invalid syntax' do
    let(:code) do
      <<~RUBY
        class Foo
          # @param [Sym bol] x
          # @return [Symbol]
          def bar(x = :sym)
            x
          end
        end
      RUBY
    end

    it 'provides corrected line for safe fix', :aggregate_failures do
      expect(result[:output]).to include('@param [Symbol] x')
      expect(result[:output]).not_to include('Sym bol')
    end
  end

  describe 'source field' do
    context 'with syntax source for invalid YARD' do
      let(:code) do
        <<~RUBY
          class Foo
            # @return [Sym bol]
            def bar
              :x
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('validate_types' => true) }

      it 'reports syntax source' do
        expect(result[:changes].first[:source]).to eq('syntax')
      end
    end

    context 'with infer source for mismatch without RBS' do
      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('validate_types' => true) }

      it 'reports infer source' do
        expect(result[:changes].first[:source]).to eq('infer')
      end
    end

    context 'with rbs source when RBS type differs' do
      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end
      let(:tmp_dir) { Dir.mktmpdir }
      let(:sig_dir) do
        dir = File.join(tmp_dir, 'sig')
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'foo.rbs'), "class Foo\n  def bar: () -> String\nend\n")
        dir
      end
      let(:rbs_config) do
        Docscribe::Config.new('validate_types' => true, 'rbs' => { 'enabled' => true, 'sig_dirs' => [sig_dir] })
      end
      let(:rbs_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: rbs_config, file: 'test.rb')
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'reports rbs source' do
        skip_unless_rbs_available!
        expect(rbs_result[:changes].first[:source]).to eq('rbs')
      end
    end
  end
end
