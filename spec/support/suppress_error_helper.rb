# frozen_string_literal: true

module SuppressErrorHelper
  # Yields block and suppresses StandardError, returning nil on error.
  #
  # @yieldreturn [Object] block result
  # @return [Object, nil] block result or nil if StandardError rescued
  def suppress_error
    yield
  rescue StandardError
    nil
  end
end
