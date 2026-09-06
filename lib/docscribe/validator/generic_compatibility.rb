# frozen_string_literal: true

require_relative '../types/primitive'
require 'docscribe/types/yard/validator'

module Docscribe
  module Validator
    # Service object answering `generic_compatible?` without hardcoding alias names.
    #
    # Dynamically decides if two type strings are compatible via generics/aliases.
    # Uses hash dispatch to avoid long if/else chains and to allow easy extension.
    module GenericCompatibility
      # Check registry: name => checker method symbol
      CHECKS = {
        generic_base: :generic_base_compatible?,
        short_name: :short_name_compatible?,
        alias_hash: :alias_hash_compatible?,
        tuple_array: :tuple_array_compatible?,
        optional_nil: :optional_nil_compatible?,
        union_containment: :union_containment?,
        optional_suffix: :optional_suffix_compatible?,
        generic_inner_alias: :generic_inner_alias_compatible?,
        union_optional: :union_vs_optional_compatible?,
        object_compatible: :object_compatible?,
        fallback_union: :fallback_union_check?
      }.freeze

      class << self
        # Whether two type strings are generic compatible (any checker true).
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @param [String] fallback_type fallback type for union checks (default "Object")
        # @param [String, Symbol, nil] method_name method name for void compatibility (e.g., "initialize")
        # @return [Boolean] true if any compatibility checker matches
        def compatible?(yard_type, expected_type, fallback_type: 'Object', method_name: nil)
          return true if void_compatible?(yard_type, expected_type, fallback_type, method_name: method_name)

          CHECKS.any? do |name, checker|
            if name == :fallback_union
              send(checker, yard_type, expected_type, fallback_type)
            else
              send(checker, yard_type, expected_type)
            end
          end
        end

        # Whether void YARD type is compatible with expected type.
        #
        # Handles fallback unions and dynamic `initialize`/`setup` compatibility
        # where `void` is treated as compatible with `Hash`, `self`, or `Boolean`
        # for initializers per Ruby idiom.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @param [String] fallback_type fallback type for union checks
        # @param [String, Symbol, nil] method_name method name for dynamic check
        # @return [Boolean] true if void compatibility holds
        def void_compatible?(yard_type, expected_type, fallback_type = 'Object', method_name: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/AbcSize
          return false unless normalize(yard_type) == 'void'

          return true if fallback_union?(expected_type, fallback_type) ||
                         %w[nil void].include?(normalize(expected_type))

          if method_name.to_s =~ /initialize|setup/
            norm = normalize(expected_type).delete_suffix('?').strip
            return true if norm == 'Hash' || norm.start_with?('Hash<') || norm.start_with?('Hash[')
            return true if %w[self Boolean].include?(norm)
          end

          if method_name.to_s.end_with?('?')
            norm = normalize(expected_type).delete_suffix('?').strip
            return true if norm == 'Boolean'
          end

          false
        end # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/AbcSize

        # Whether either type is a fallback-only union for the given fallback type.
        #
        # Delegates to {#fallback_union?} for both yard_type and expected_type.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @param [String] fallback_type fallback type to match (e.g., "Object")
        # @return [Boolean] true if either type contains only fallback parts
        def fallback_union_check?(yard_type, expected_type, fallback_type)
          fallback_union?(yard_type, fallback_type) || fallback_union?(expected_type, fallback_type)
        end

        # Whether a type string contains only the fallback type (comma-separated, ignoring trailing `?`).
        #
        # @param [String, nil] type_str type string to test, may be comma-separated union
        # @param [String] fallback fallback type name (e.g., "Object")
        # @return [Boolean] true if every comma-separated part equals the normalized fallback
        def fallback_union?(type_str, fallback)
          return false if type_str.nil? || type_str.strip.empty?

          fallback_norm = normalize(fallback)
          parts = type_str.to_s.split(',').map { |part| normalize(part.strip.delete_suffix('?').strip) }
          parts.all? { |part| part == fallback_norm || part.empty? }
        end

        # Whether generic base matches: Hash vs Hash<Symbol,String> or Array vs Array<String>.
        #
        # True when normalized types equal or one is bare base of the other's generic.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if generic base matches (bare vs generic or identical)
        def generic_base_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type)
          norm_expected = normalize(expected_type)
          return true if norm_yard == norm_expected

          yard_generic = norm_expected !~ /[<\[]/ && (norm_yard.start_with?("#{norm_expected}<") || norm_yard.start_with?("#{norm_expected}["))
          expected_generic = norm_yard !~ /[<\[]/ && (norm_expected.start_with?("#{norm_yard}<") || norm_expected.start_with?("#{norm_yard}["))
          yard_generic || expected_generic
        end

        # Whether short names equal: Docscribe::Config vs Config, Parser::Source::Range vs Range.
        #
        # Ignores generic brackets and checks namespace-elided compatibility via {#short_compatible?}.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if short names match with namespace variation
        def short_name_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type)
          norm_expected = normalize(expected_type)
          return false if generic_string?(norm_yard) || generic_string?(norm_expected)

          short_yard = short_name(norm_yard)
          short_expected = short_name(norm_expected)
          short_compatible?(short_yard, short_expected, norm_yard, norm_expected)
        end

        # Short name without namespace or generic args.
        #
        # Strips module prefix and generic suffix. E.g., "Docscribe::Config<String>" => "Config".
        #
        # @param [String] type_str raw type string, may be nil
        # @return [String] short name (last namespace segment without < or [)
        def short_name(type_str)
          normalize(type_str).split('::').last.to_s.split('<').first.split('[').first.strip
        end

        # Whether a normalized type string contains generic brackets.
        #
        # @param [String] normalized normalized type string (after {#normalize})
        # @return [Boolean] true if string includes "<" or "[" indicating generic
        def generic_string?(normalized) # rubocop:disable SortedMethodsByCall/Waterfall
          normalized.include?('<') || normalized.include?('[')
        end

        # Whether short names are compatible given full normalized forms.
        #
        # Allows Docscribe::Config vs Config and cross-checks short vs full forms.
        #
        # @param [String] short_yard short name derived from YARD type
        # @param [String] short_expected short name derived from expected type
        # @param [String] norm_yard full normalized YARD type
        # @param [String] norm_expected full normalized expected type
        # @return [Boolean] true if short names align via namespace elision
        def short_compatible?(short_yard, short_expected, norm_yard, norm_expected)
          return true if short_yard == short_expected && short_yard != norm_yard && short_expected != norm_expected
          return true if short_yard == norm_expected
          return true if short_expected == norm_yard

          false
        end

        # Whether alias (lowercase after ::) vs Hash/Array/Range is compatible.
        #
        # Checks if one side is a namespaced alias starting with lowercase and the other is Hash, Array, or Range.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if alias vs Hash/Array/Range pair detected
        def alias_hash_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type)
          norm_expected = normalize(expected_type)
          hash_like = %w[Hash Array Range]
          [[norm_yard, norm_expected], [norm_expected, norm_yard]].any? do |alias_type, hash_type|
            base = base_name(hash_type)
            next false unless hash_like.include?(base) || hash_type.start_with?('Hash') || hash_type.start_with?('Array') || hash_type == 'Range'

            short_alias = alias_type.split('::').last.to_s
            short_alias =~ /\A[a-z]/ && alias_type.include?('::')
          end
        end

        # Base name before generic or paren.
        #
        # Strips "<", "[", "(" suffixes. E.g., "Hash<Symbol,String>" => "Hash".
        #
        # @param [String] type_str raw type string, may be nil
        # @return [String] base type name without generic arguments
        def base_name(type_str)
          normalize(type_str).split('<').first.split('[').first.split('(').first.strip
        end

        # Whether tuple "(String, Integer)" vs Array is compatible.
        #
        # True when one side is bare "Array" and the other is parenthesized tuple.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if tuple vs Array pair
        def tuple_array_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type)
          norm_expected = normalize(expected_type)
          (norm_expected == 'Array' && norm_yard =~ /\A\(.*\)\z/) || (norm_yard == 'Array' && norm_expected =~ /\A\(.*\)\z/)
        end

        # Whether optional vs nil pair is compatible.
        #
        # Delegates to {#question_nil_pair?}, {#comma_nil_pair?}, and {#node_nil_pair?}.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if any nil-optional pairing matches
        def optional_nil_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type)
          norm_expected = normalize(expected_type)
          return true if question_nil_pair?(norm_yard, norm_expected)
          return true if comma_nil_pair?(norm_yard, norm_expected)

          node_nil_pair?(norm_yard, norm_expected)
        end

        # Whether one side is "nil" and the other uses trailing "?" optional syntax.
        #
        # E.g., "nil" vs "String?" is considered compatible.
        #
        # @param [String] norm_yard normalized YARD type
        # @param [String] norm_expected normalized expected type
        # @return [Boolean] true if nil vs "?" optional pair
        def question_nil_pair?(norm_yard, norm_expected)
          (norm_yard == 'nil' && norm_expected.end_with?('?')) || (norm_expected == 'nil' && norm_yard.end_with?('?'))
        end

        # Whether one side is "nil" and the other contains ", nil" union.
        #
        # E.g., "nil" vs "String, nil" is considered compatible.
        #
        # @param [String] norm_yard normalized YARD type
        # @param [String] norm_expected normalized expected type
        # @return [Boolean] true if nil vs comma-nil union pair
        def comma_nil_pair?(norm_yard, norm_expected)
          (norm_yard.include?(', nil') && norm_expected == 'nil') || (norm_expected.include?(', nil') && norm_yard == 'nil')
        end

        # Whether Parser::AST::Node vs nil is considered compatible.
        #
        # Special-case for AST nodes where nil represents absent node.
        #
        # @param [String] norm_yard normalized YARD type
        # @param [String] norm_expected normalized expected type
        # @return [Boolean] true if Parser::AST::Node vs nil pair
        def node_nil_pair?(norm_yard, norm_expected)
          (norm_yard == 'Parser::AST::Node' && norm_expected == 'nil') || (norm_expected == 'Parser::AST::Node' && norm_yard == 'nil')
        end

        # Whether one type is contained in the other's comma-separated union.
        #
        # Checks both directions after normalization (e.g., "String" in "String, Integer").
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if one type appears in the other's union parts
        def union_containment?(yard_type, expected_type)
          return false if yard_type.nil? || expected_type.nil?

          norm_yard = normalize(yard_type)
          expected_type.split(',').any? { |part| normalize(part) == norm_yard } ||
            yard_type.split(',').any? { |part| normalize(part) == normalize(expected_type) }
        end

        # Whether types match after stripping trailing "?".
        #
        # E.g., "String" vs "String?" considered compatible.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if types equal ignoring optional "?" suffix
        def optional_suffix_compatible?(yard_type, expected_type)
          normalize(yard_type).delete_suffix('?') == normalize(expected_type).delete_suffix('?')
        end

        # Whether Array/Hash generic inners contain alias tokens.
        #
        # True when both are Array/Hash generics and either inner contains an alias (lowercase or "::").
        # E.g., "Array<my_alias>" vs "Array<String>".
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if generic inners alias-compatible
        def generic_inner_alias_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type)
          norm_expected = normalize(expected_type)
          return false unless generic_pair?(norm_yard, norm_expected)

          inner_yard = extract_inner(norm_yard)
          inner_expected = extract_inner(norm_expected)
          return false unless inner_yard && inner_expected

          inner_has_alias?(inner_yard) || inner_has_alias?(inner_expected)
        end

        # Whether both normalized types are Array or Hash generics.
        #
        # @param [String] norm_yard normalized YARD type
        # @param [String] norm_expected normalized expected type
        # @return [Boolean] true if both match Array/Hash generic pattern
        def generic_pair?(norm_yard, norm_expected)
          norm_yard =~ /\A(?:Array|Hash)[<\[]/ && norm_expected =~ /\A(?:Array|Hash)[<\[]/
        end

        # Extracts inner generic arguments from normalized Array/Hash type.
        #
        # E.g., "Array<String>" => "String", "Hash<Symbol, String>" => "Symbol, String".
        #
        # @param [String] normalized normalized generic type string
        # @return [String, nil] inner content or nil if not generic
        def extract_inner(normalized)
          normalized[/\A(?:Array|Hash)[<\[](.*)[>\]]\z/, 1]
        end

        # Whether any comma-separated part of generic inner is an alias token.
        #
        # @param [String] inner inner generic string (comma-separated)
        # @return [Boolean] true if any part satisfies {#alias_token?}
        def inner_has_alias?(inner)
          inner.split(',').any? { |part| alias_token?(part.strip) }
        end

        # Whether token looks like an alias (dynamic, not hardcoded Elem/U).
        #
        # Any token that is not a known Ruby/YARD primitive is considered alias.
        # E.g., `Elem`, `U`, `my_alias`, `Foo::Bar`, `change` vs `String`, `Integer`, `Hash`.
        #
        # @param [String] token single type token (trimmed inner part, may include ?)
        # @return [Boolean] true if token is alias (unknown primitive or namespaced/lowercase)
        def alias_token?(token)
          base = token.split('<').first.split('[').first.strip.delete_suffix('?').strip
          return false if Docscribe::Types::Primitive.primitive?(base)
          return true if base =~ /\A[a-z]/ || base.include?('::')

          base =~ /\A[A-Z][A-Za-z0-9_]*\z/
        end

        # Whether union `?, nil` forms are compatible: `Object?` vs `Object, nil` vs `Object|nil`.
        #
        # Handles all three forms `SomeType? == SomeType|nil == SomeType, nil` plus
        # bare `SomeType` vs optional equivalence via pipe/comma normalization.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if one is `Type?` and other is `Type, nil` / `Type|nil`
        def union_vs_optional_compatible?(yard_type, expected_type)
          norm_yard = normalize(yard_type).gsub('|', ',')
          norm_expected = normalize(expected_type).gsub('|', ',')
          return true if question_vs_comma_nil?(norm_yard, norm_expected)
          return true if suffix_vs_union_first?(yard_type, expected_type)
          return true if pipe_aware_suffix_vs_union_first?(yard_type, expected_type)

          optional_forms_equal?(yard_type, expected_type)
        end

        # Pipe-aware variant of {#suffix_vs_union_first?} normalizing `|` to `,`.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if suffix vs union matches after pipe normalization
        def pipe_aware_suffix_vs_union_first?(yard_type, expected_type)
          # Normalize both by converting pipe to comma before comparison
          y = yard_type.to_s.gsub('|', ',')
          e = expected_type.to_s.gsub('|', ',')
          left_match = normalize(y).delete_suffix('?') ==
                       normalize(split_top_level_commas_local(e).first || '')
          right_match = normalize(e).delete_suffix('?') ==
                        normalize(split_top_level_commas_local(y).first || '')
          left_match || right_match
        end

        # Whether optional forms `T?`, `T, nil`, `T|nil` are equivalent (same canonical parts).
        #
        # Canonicalizes `T?` => `[T, nil]`, `T, nil` / `T|nil` => `[T, nil]`, `T` => `[T]`.
        # Generic-aware split keeps `Hash<String, Integer>, nil` intact.
        #
        # @param [String, nil] first first type string
        # @param [String, nil] second second type string
        # @return [Boolean] true if canonical optional parts equal and non-empty
        def optional_forms_equal?(first, second)
          pa = optional_canonical_parts(first)
          pb = optional_canonical_parts(second)
          !pa.empty? && pa == pb
        end

        # Whether Object supertype compatibility holds: e.g., String vs Object, String, nil vs Object, nil.
        #
        # If expected is Object (or Object, nil, Object? etc) and yard is a concrete type
        # (String, Array<String>, etc) with same nil presence, then yard is considered
        # compatible with expected since Object is supertype of all. Handles
        # receiver_or_and_type: String, nil vs Object, nil dynamically.
        #
        # @param [String, nil] yard_type YARD type string
        # @param [String, nil] expected_type inferred/RBS type string
        # @return [Boolean] true if Object supertype compatibility holds
        def object_compatible?(yard_type, expected_type) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          yard_canonical = optional_canonical_parts(yard_type)
          exp_canonical = optional_canonical_parts(expected_type)
          return false if yard_canonical.empty? || exp_canonical.empty?

          yard_without_nil = canonical_without_nil(yard_canonical)
          exp_without_nil = canonical_without_nil(exp_canonical)
          if (exp_without_nil == ['Object'] && yard_without_nil != ['Object'] && !yard_without_nil.empty?) ||
             (yard_without_nil == ['Object'] && exp_without_nil != ['Object'] && !exp_without_nil.empty?)
            return yard_canonical.include?('nil') == exp_canonical.include?('nil')
          end

          false
        end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # @param [Object] canonical
        # @return [Object]
        def canonical_without_nil(canonical)
          canonical.reject { |p| p == 'nil' }
        end

        # Canonical optional parts for `T?` / `T, nil` / `T|nil` / `T` forms.
        #
        # @param [String, nil] str raw type string
        # @return [Array<String>] sorted unique normalized parts
        def optional_canonical_parts(str) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          return [] if str.nil? || str.to_s.strip.empty?

          s = str.to_s.gsub('|', ',').strip
          # Single optional without comma: "String?" => ["String", "nil"]
          if s.end_with?('?') && !s.include?(',')
            base = normalize(s.delete_suffix('?').strip)
            return [base, 'nil'].sort
          end

          parts = split_top_level_commas_local(s)
          expanded = parts.flat_map do |part|
            stripped = part.strip
            if stripped.end_with?('?')
              [normalize(stripped.delete_suffix('?').strip), 'nil']
            else
              [normalize(stripped)]
            end
          end
          expanded.map { |part| normalize(part) }.reject(&:empty?).uniq.sort
        end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

        # Split by top-level commas outside `< > [ ] ( )` (generic-aware).
        #
        # Mirrors `Docscribe::Infer::Returns.split_top_level_commas` but local to avoid cross-dep.
        #
        # @param [String] str type string to split
        # @return [Array<String>] parts split on top-level commas
        def split_top_level_commas_local(str) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          state = { parts: [], cur: +'', da: 0, db: 0, dp: 0 } #: Hash[Symbol, untyped]
          str.each_char do |chr| # rubocop:disable Metrics/BlockLength
            case chr
            when '<'
              state[:da] += 1
              state[:cur] << chr
            when '>'
              state[:da] -= 1
              state[:cur] << chr
            when '['
              state[:db] += 1
              state[:cur] << chr
            when ']'
              state[:db] -= 1
              state[:cur] << chr
            when '('
              state[:dp] += 1
              state[:cur] << chr
            when ')'
              state[:dp] -= 1
              state[:cur] << chr
            when ','
              if state[:da].zero? && state[:db].zero? && state[:dp].zero?
                state[:parts] << state[:cur]
                state[:cur] = +''
              else
                state[:cur] << ','
              end
            else
              state[:cur] << chr
            end
          end # rubocop:enable Metrics/BlockLength
          state[:parts] << state[:cur] unless state[:cur].empty?
          state[:parts]
        end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

        # Method documentation.
        #
        # @param [String] norm_yard Param documentation.
        # @param [String] norm_expected Param documentation.
        # @return [Boolean]
        def question_vs_comma_nil?(norm_yard, norm_expected)
          norm_yard.delete(' ') == "#{norm_expected.delete(' ').delete_suffix('?')},nil" ||
            norm_expected.delete(' ') == "#{norm_yard.delete(' ').delete_suffix('?')},nil"
        end

        # Method documentation.
        #
        # @param [String, nil] yard_type Param documentation.
        # @param [String, nil] expected_type Param documentation.
        # @return [Boolean]
        def suffix_vs_union_first?(yard_type, expected_type)
          normalize(yard_type).delete_suffix('?') == normalize(expected_type).split(',').first&.strip ||
            normalize(expected_type).delete_suffix('?') == normalize(yard_type).split(',').first&.strip
        end

        # Normalizes type string for comparison.
        #
        # Strips, squeezes spaces, converts "["/"]" to "<"/">", replaces "untyped"/"FALLBACK_TYPE" with "Object".
        #
        # @param [String, nil] type_str raw type string, may be nil
        # @return [String] normalized type string
        def normalize(type_str)
          type_str.to_s.strip.squeeze(' ').gsub('[', '<').gsub(']', '>').gsub(/\buntyped\b/, 'Object')
                  .gsub(/\bFALLBACK_TYPE\b/, 'Object')
        end
      end
    end
  end
end
