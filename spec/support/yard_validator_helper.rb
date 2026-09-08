# frozen_string_literal: true

require 'docscribe/types/yard/validator'

module YardValidatorHelper
  # @param [String, nil] type_str
  # @return [Boolean]
  def invalid_yard_type?(type_str)
    !valid_yard_type?(type_str)
  end

  # @param [String, nil] type_str
  # @return [Boolean]
  def valid_yard_type?(type_str)
    Docscribe::Types::Yard::Validator.valid?(type_str)
  end

  # @param [String, nil] type_str
  # @return [Boolean]
  def valid_yard_syntax?(type_str)
    Docscribe::Types::Yard::Validator.syntax_valid?(type_str)
  end

  # @param [String, nil] type_str
  # @return [Boolean]
  def balanced_yard_brackets?(type_str)
    Docscribe::Types::Yard::Validator.balanced_brackets?(type_str)
  end

  # @param [String, nil] type_str
  # @return [Boolean]
  def fully_consumed_yard_type?(type_str)
    Docscribe::Types::Yard::Validator.fully_consumed?(type_str)
  end

  # @param [String] str
  # @return [Docscribe::Types::Yard::node, nil]
  def parse_yard_type(str)
    Docscribe::Types::Yard.parse(str)
  end
end

RSpec::Matchers.define :be_valid_yard_type do
  match { |actual| Docscribe::Types::Yard::Validator.valid?(actual) }
  failure_message { |actual| "expected #{actual.inspect} to be valid YARD type, but was invalid" }
  failure_message_when_negated { |actual| "expected #{actual.inspect} not to be valid YARD type, but was valid" }
end

RSpec::Matchers.define :be_valid_yard_syntax do
  match { |actual| Docscribe::Types::Yard::Validator.syntax_valid?(actual) }
  failure_message { |actual| "expected #{actual.inspect} to have valid YARD syntax" }
  failure_message_when_negated { |actual| "expected #{actual.inspect} not to have valid YARD syntax" }
end

RSpec::Matchers.define :be_invalid_yard_type do
  match { |actual| !Docscribe::Types::Yard::Validator.valid?(actual) }
  failure_message { |actual| "expected #{actual.inspect} to be invalid YARD type, but was valid" }
  failure_message_when_negated { |actual| "expected #{actual.inspect} not to be invalid YARD type" }
end
