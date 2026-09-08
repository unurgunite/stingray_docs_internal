# frozen_string_literal: true

RSpec.describe Docscribe::Infer do
  subject(:out) { inline(code, config: conf) }

  let(:conf) { Docscribe::Config.new('emit' => { 'header' => true }) }

  describe 'if/else branches with different types' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if cond
              :ok
            else
              { error: "failed" }
            end
          end
        end
      RUBY
    end

    it 'returns union of Symbol and Hash when branches differ' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol, Hash'))
    end
  end

  describe 'if/else where one branch is nil' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if cond
              42
            end
          end
        end
      RUBY
    end

    it 'returns Integer? when else is implicitly nil' do
      expect(out).to match(header_regex('A', 'foo', 'Integer?'))
    end
  end

  describe 'if/else with explicit nil' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if cond
              "hello"
            else
              nil
            end
          end
        end
      RUBY
    end

    it 'returns String? when one branch is nil' do
      expect(out).to match(header_regex('A', 'foo', 'String?'))
    end
  end

  describe 'if/else with same type in both branches' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if cond
              1
            else
              2
            end
          end
        end
      RUBY
    end

    it 'collapses identical types to a single type' do
      expect(out).to match(header_regex('A', 'foo', 'Integer'))
    end
  end

  describe 'if/elsif/else with multiple types' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if cond == 1
              :one
            elsif cond == 2
              "two"
            else
              nil
            end
          end
        end
      RUBY
    end

    it 'returns union of all branch types' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol, String'))
    end
  end

  describe 'case/when with different types' do
    let(:code) do
      <<~RUBY
        class A
          def foo(x)
            case x
            when 1 then :ok
            when 2 then "maybe"
            else 42
            end
          end
        end
      RUBY
    end

    it 'returns union of all when branch types' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol, String'))
    end
  end

  describe 'nested if/else with different types' do
    let(:code) do
      <<~RUBY
        class A
          def foo(a, b)
            if a
              if b
                :ok
              else
                "fallback"
              end
            else
              42
            end
          end
        end
      RUBY
    end

    it 'returns union of all nested branch types' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol, String'))
    end
  end

  describe 'if with only one branch (no else)' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if cond
              :ok
            end
          end
        end
      RUBY
    end

    it 'handles nil else branch' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol?'))
    end
  end

  describe 'if/case-elsif — case inside if with else nil, elsif literal' do
    let(:code) do
      <<~RUBY
        class A
          def foo(cond)
            if 123
              case cond
              when 1 then :abc
              end
            elsif :smth
              333
            end
          end
        end
      RUBY
    end

    it 'unifies case branch (Symbol), elsif (Integer?), missing outer else (nil)' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol?, Integer?'))
    end
  end

  describe 'case/when with if/elsif/else inside' do
    let(:code) do
      <<~RUBY
        class A
          def foo(x)
            case x
            when 1
              if x > 0
                :pos
              elsif x == 0
                :zero
              else
                :neg
              end
            when 2
              "string"
            end
          end
        end
      RUBY
    end

    it 'unifies nested if/elsif/else with other when branch' do
      expect(out).to match(header_regex('A', 'foo', 'Symbol, String?'))
    end
  end
end
