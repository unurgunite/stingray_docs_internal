# frozen_string_literal: true

module InlineHelper
  # Run Docscribe's inline rewriter on +code+ with the given configuration and strategy.
  #
  # Defaults to safe mode and an empty config when no arguments are provided.
  #
  # @param [String] code Ruby source code to rewrite
  # @param [Docscribe::Config, nil] config configuration (defaults to empty)
  # @param [Symbol] strategy rewrite strategy (:safe or :aggressive)
  # @param [String] file file with Ruby source code
  # @return [String] rewritten source code
  def inline(code, config: Docscribe::Config.new, strategy: :safe, file: nil)
    Docscribe::InlineRewriter.insert_comments(code, strategy: strategy, config: config, file: file)
  end
end
