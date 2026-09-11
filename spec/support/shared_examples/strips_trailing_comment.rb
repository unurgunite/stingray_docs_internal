# frozen_string_literal: true

RSpec.shared_examples 'strips trailing comment' do |method_name|
  it 'strips spaced comment' do
    expect(send(method_name, 'Hash<Object,Object> # foobar')).to eq('Hash<Object,Object>')
  end

  it 'strips tight comment without space' do
    expect(send(method_name, 'Hash<Object,Object>#foobar')).to eq('Hash<Object,Object>')
  end

  it 'strips spaced comment with multiple words' do
    expect(send(method_name, 'Hash<Object,Object> # comment with spaces')).to eq('Hash<Object,Object>')
  end

  it 'strips comment after bracket syntax' do
    expect(send(method_name, 'Hash[Symbol, String] # comment')).to eq('Hash<Symbol, String>')
  end

  it 'does not strip duck type starting with #' do
    expect(send(method_name, '#foo')).to eq('#foo')
  end

  it 'does not strip duck type with leading spaces' do
    expect(send(method_name, '  #foo')).to eq('#foo')
  end

  it 'handles empty after stripping comment only' do
    expect(send(method_name, '# comment only')).to eq('# comment only')
  end

  it 'handles type with trailing comment and newline' do
    expect(send(method_name, "Hash<Object,Object> #foobar\n")).to eq('Hash<Object,Object>')
  end

  it 'handles String with trailing comment' do
    expect(send(method_name, 'String # comment')).to eq('String')
  end

  it 'handles Array nested generic with tight comment' do
    expect(send(method_name, 'Array<Hash<String,Integer>>#foobar')).to eq('Array<Hash<String,Integer>>')
  end

  it 'handles Object fallback with comment' do
    expect(send(method_name, 'Object # fallback comment')).to eq('Object')
  end

  it 'handles optional nil with comment' do
    expect(send(method_name, 'String? # optional')).to eq('String?')
  end

  it 'handles Hash with inner comment after generic close' do
    expect(send(method_name, 'Hash<String, Integer> # trailing')).to eq('Hash<String, Integer>')
  end
end
