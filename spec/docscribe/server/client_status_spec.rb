# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass -- tests the exe script, not a class
RSpec.describe 'docscribe-client --status' do
  subject(:reported_status) { JSON.parse(client_output)['status'] }

  let(:client_exe) { File.expand_path('../../../exe/docscribe-client', __dir__) }
  let(:workdir) { Dir.mktmpdir }
  let(:client_output) do
    out, _status = Open3.capture2('ruby', client_exe, '--status', chdir: workdir)
    out
  end
  let(:socket_path) do
    out, _status = Open3.capture2('ruby', client_exe, '--socket-path', chdir: workdir)
    out.strip
  end

  after { FileUtils.rm_rf(workdir) }

  it 'reports not_running when no daemon listens' do
    expect(reported_status).to eq('not_running')
  end

  context 'with a server accepting on the socket' do
    subject(:reported_status) do
      with_dummy_server(socket_path) { JSON.parse(client_output)['status'] }
    end

    it 'reports running' do
      expect(reported_status).to eq('running')
    end
  end

  context 'with a stale socket file' do
    subject(:reported_status) do
      with_dummy_server(socket_path) { nil }
      JSON.parse(client_output)['status']
    end

    it 'reports not_running' do
      expect(reported_status).to eq('not_running')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
