# frozen_string_literal: true

RSpec.shared_examples 'correct exit status' do
  it 'exits 1 in check mode when updates needed' do
    expect(result[2].exitstatus).to eq(1)
  end
end
