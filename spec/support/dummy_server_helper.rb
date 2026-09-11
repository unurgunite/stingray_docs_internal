# frozen_string_literal: true

require 'socket'

module DummyServerHelper
  # Method documentation.
  #
  # @param [Object] sock Param documentation.
  # @return [Object]
  def with_dummy_server(sock)
    server = UNIXServer.new(sock)
    thread = Thread.new { drain_server(server) }
    yield
  ensure
    server.close
    thread.kill
    thread.join(5)
  end

  private

  # Method documentation.
  #
  # @private
  # @param [Object] server Param documentation.
  # @raise [IOError]
  # @raise [Errno::EBADF]
  # @return [Object]
  # @return [nil] if IOError, Errno::EBADF
  def drain_server(server)
    loop do
      client = server.accept
      client&.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end
