# frozen_string_literal: true

RSpec.describe Docscribe::InlineRewriter do
  subject(:out) { inline(code, strategy: :safe) }

  let(:code) { "class A\n\t# @todo docs\n\tdef foo(x)\n\t  x\n\tend\nend\n" }

  it 'preserves tab indentation in merged additions' do
    expect(out).to include("\t# @param [Object] x")
  end
end
