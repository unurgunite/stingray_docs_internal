# frozen_string_literal: true

RSpec.describe Docscribe::InlineRewriter do
  describe 'Boolean and Hash from keyword defaults' do
    subject(:output) { inline(code) }

    let(:code) do
      <<~RUBY
        class Demo
          def foo(verbose: true, options: {}); 0; end
        end
      RUBY
    end

    it 'infers Boolean and Hash from keyword defaults', :aggregate_failures do
      expect(output).to include('@param [Boolean] verbose')
      expect(output).to include('@param [Hash] options')
    end
  end

  describe 'Array/Hash/Proc for splats and block' do
    subject(:output) { inline(code) }

    let(:code) do
      <<~RUBY
        class Demo
          def foo(*args, **kwargs, &block); 0; end
        end
      RUBY
    end

    it 'infers Array/Hash/Proc for splats and block', :aggregate_failures do
      expect(output).to include('@param [Array] args')
      expect(output).to include('@param [Hash] kwargs')
      expect(output).to include('@param [Proc] block')
    end
  end

  describe 'Integer and Symbol for return types from literals' do
    subject(:output) { inline(code, config: config) }

    let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }
    let(:code) do
      <<~RUBY
        class Demo
          def a; 42; end
          def b; :ok; end
        end
      RUBY
    end

    it 'infers Integer and Symbol for return types from literals', :aggregate_failures do
      expect(output).to match(header_regex('Demo', 'a', 'Integer'))
      expect(output).to include('@return [Integer]')
      expect(output).to match(header_regex('Demo', 'b', 'Symbol'))
      expect(output).to include('@return [Symbol]')
    end
  end

  describe 'required keyword without default' do
    subject(:output) { inline(code) }

    let(:code) do
      <<~RUBY
        class Demo
          def foo(options:, kw:); 0; end
        end
      RUBY
    end

    it 'treats required keyword without default as Object; but options: without default as Hash', :aggregate_failures do
      expect(output).to include('@param [Hash] options')
      expect(output).to include('@param [Object] kw')
    end
  end
end
