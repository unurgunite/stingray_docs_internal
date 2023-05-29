# frozen_string_literal: true

class Object # :nodoc:
  # +Object#could_be_hash?+                           -> Object
  #
  # Returns true if the given object can be parsed as JSON hash, false otherwise.
  #
  # @param [String] obj The object to check.
  # @return [TrueClass] True if the object can be parsed as a JSON hash.
  # @return [FalseClass] False if object can not be parsed as a JSON hash.
  def could_be_hash?(obj)
    JSON.parse(obj).is_a?(Hash)
  rescue JSON::ParserError, TypeError
    false
  end
end
