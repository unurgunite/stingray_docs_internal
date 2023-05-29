# frozen_string_literal: true

require "parser/current"

module MethodAnalyzer # :nodoc:
  class << self
    # +MethodAnalyzer.private_methods_list+    -> Object
    #
    # Returns a list of private methods in the given code.
    #
    # @!scope class
    # @param [Object] code The source code to analyze.
    # @return [Array] An array of private method names.
    def private_methods_list(code)
      ast = Parser::CurrentRuby.parse(code)
      traverse(ast).first
    end

    private

    # +MethodAnalyzer.traverse+    -> Object
    #
    # Traverses the AST and returns a list of private methods.
    #
    # @param [Object] node The current AST node.
    # @param [Array] private_methods The list of private methods found so far.
    # @param [Symbol] current_scope The current scope (:public or :private).
    # @return [Array] An array containing the list of private methods and the current scope.
    def traverse(node, private_methods = [], current_scope = :public)
      case node.type
      when :class, :module, :sclass
        new_scope = current_scope
        children = node.children.last.type == :begin ? node.children.last.children : [node.children.last]
        children.each do |child|
          private_methods, new_scope = traverse(child, private_methods, new_scope)
        end
      when :def, :defs
        private_methods << node.children.first if current_scope == :private && node.children.first.is_a?(Symbol)
        new_scope = current_scope
      when :send
        new_scope = node.children.last == :private ? :private : current_scope
      else
        new_scope = current_scope
      end
      [private_methods, new_scope]
    end
  end
end
