# frozen_string_literal: true

require_relative 'parser'

module Docscribe
  module Types
    module Yard
      # Validates YARD type strings for syntax errors.
      #
      # This validator is intentionally lightweight and does not perform
      # semantic type-existence checks (e.g. `Symbol2l` vs `Symbol`).
      # Semantic checks are handled by `Docscribe::Validator::TypeMismatchValidator`
      # which compares a YARD tag against the inferred / RBS type.
      module Validator
        module_function

        # Check if a YARD type string is syntactically valid.
        #
        # Criteria:
        # - non-empty after strip
        # - brackets are balanced (`<>`, `()`, `{}`, `[]`)
        # - no `,,`, `<>`, `,]` artefacts
        # - `Yard::Parser` consumes the entire string (catches `Sym bol` leftover)
        #
        # @note module_function: defines #valid? (visibility: private)
        # @param [String, nil] type_str the YARD type string to validate (e.g. "String", "Array<String>", "Sym bol")
        # @raise [StandardError]
        # @return [Boolean]
        # @return [Boolean] if StandardError
        def valid?(type_str)
          syntax_valid?(type_str)
        rescue StandardError
          false
        end

        # Strict syntax validation with balanced brackets and full consumption.
        #
        # @note module_function: defines #syntax_valid? (visibility: private)
        # @param [String, nil] type_str
        # @raise [StandardError]
        # @return [Boolean]
        # @return [Boolean] if StandardError
        def syntax_valid?(type_str)
          return false if blank_type?(type_str)
          return false unless balanced_brackets?(type_str)
          return false if artefact_type?(type_str)

          fully_consumed?(type_str)
        rescue StandardError
          false
        end

        # @note module_function: defines #blank_type? (visibility: private)
        # @param [String, nil] type_str
        # @return [Boolean]
        def blank_type?(type_str)
          type_str.nil? || type_str.strip.empty?
        end

        # @note module_function: defines #artefact_type? (visibility: private)
        # @param [String, nil] type_str
        # @return [Boolean]
        def artefact_type?(type_str)
          return false if type_str.nil?

          type_str.include?(',,') || type_str.include?('<>') || type_str.include?(',]')
        end

        # Check balanced brackets for `<>`, `()`, `{}`, `[]`.
        #
        # @note module_function: defines #balanced_brackets? (visibility: private)
        # @param [String, nil] type_str
        # @return [Boolean]
        def balanced_brackets?(type_str)
          return false if type_str.nil?

          stack = [] #: Array[String]
          pairs = { '>' => '<', ')' => '(', '}' => '{', ']' => '[' }
          opens = pairs.values

          type_str.each_char do |ch|
            return false unless process_bracket_char?(ch, stack, pairs, opens)
          end

          stack.empty?
        end

        # @note module_function: defines #process_bracket_char? (visibility: private)
        # @param [String] char
        # @param [Array<String>] stack
        # @param [Hash<String, String>] pairs
        # @param [Array<String>] opens
        # @return [Boolean]
        def process_bracket_char?(char, stack, pairs, opens)
          if opens.include?(char)
            stack << char
          elsif pairs.key?(char)
            return false if stack.empty? || stack.pop != pairs[char]
          end
          true
        end

        # Whether `Yard::Parser` consumes the entire string.
        #
        # Catches cases like `Sym bol` where parser would return `Sym` and
        # leave ` bol` unconsumed.
        #
        # @note module_function: defines #fully_consumed? (visibility: private)
        # @param [String, nil] type_str
        # @raise [StandardError]
        # @return [Boolean]
        # @return [Boolean] if StandardError
        def fully_consumed?(type_str)
          return false if type_str.nil?

          stripped = type_str.strip
          parser = Parser.new(stripped)
          node = parser.parse
          return false unless node

          idx = parser.instance_variable_get(:@i)
          # `Parser#parse` calls `skip_space` before and after `parse_union`,
          # so `idx` should be at the end if fully consumed.
          idx == stripped.length
        rescue StandardError
          false
        end
      end
    end
  end
end
