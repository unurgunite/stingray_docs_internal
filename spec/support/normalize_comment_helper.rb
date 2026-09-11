# frozen_string_literal: true

module NormalizeCommentHelper
  # Method documentation.
  #
  # @param [String] str Param documentation.
  # @return [Object]
  def generic_normalize(str)
    generic_mod.send(:normalize, str)
  end

  # Method documentation.
  #
  # @param [String] str Param documentation.
  # @return [Object]
  def validator_normalize(str)
    validator.send(:normalize, str)
  end

  # Method documentation.
  #
  # @param [String] str Param documentation.
  # @return [Object]
  def builder_normalize(str)
    builder.send(:normalize_type, str)
  end
end
