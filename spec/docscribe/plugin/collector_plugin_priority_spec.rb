# frozen_string_literal: true

RSpec.describe Docscribe::Plugin::Base::CollectorPlugin do
  subject(:out) { inline(code, config: conf) }

  let(:conf) { Docscribe::Config.new('emit' => { 'header' => true }) }
  let(:code) { raise 'define `code` in a context' }

  after { Docscribe::Plugin::Registry.clear! }

  # IMPORTANT:
  # Under Ruby 3.4+ Docscribe may parse via Prism translation, and the returned AST
  # may not have `each_node`. So in tests we avoid `each_node` to mimic real-world
  # plugin robustness.

  context 'when two CollectorPlugins target the same anchor with different priorities' do
    before do
      low  = build_collector_plugin("# LOW\n")
      high = build_collector_plugin("# HIGH\n")

      Docscribe::Plugin::Registry.register(low, priority: 1)
      Docscribe::Plugin::Registry.register(high, priority: 2)
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

    it 'keeps only the highest priority CollectorPlugin insertion at the same anchor', :aggregate_failures do
      expect(out).to include('# HIGH')
      expect(out).not_to include('# LOW')
    end
  end

  context 'when two CollectorPlugins target the same anchor with the same max priority' do
    before do
      a = build_collector_plugin("# A\n")
      b = build_collector_plugin("# B\n")

      Docscribe::Plugin::Registry.register(a, priority: 5)
      Docscribe::Plugin::Registry.register(b, priority: 5)
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

    it 'keeps all plugin insertions on a tie (same max priority)', :aggregate_failures do
      expect(out).to include('# A')
      expect(out).to include('# B')
    end
  end
end
