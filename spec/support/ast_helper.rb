# frozen_string_literal: true

module AstHelper
  # Find a `def` node with the given name inside an AST.
  #
  # @param [Parser::AST::Node] node root node
  # @param [Symbol] name method name
  # @return [Parser::AST::Node, nil]
  def find_def(node, name)
    return nil unless node.is_a?(Parser::AST::Node)
    return node if node.type == :def && node.children[0] == name

    node.children.each do |child|
      next unless child.is_a?(Parser::AST::Node)

      found = find_def(child, name)
      return found if found
    end
    nil
  end

  # Find the first `def` or `defs` node in an AST.
  #
  # @param [Parser::AST::Node] node root node
  # @return [Parser::AST::Node, nil]
  def find_first_def(node)
    return node if node.is_a?(Parser::AST::Node) && %i[def defs].include?(node.type)
    return nil unless node.is_a?(Parser::AST::Node)

    node.children.each do |child|
      found = find_first_def(child)
      return found if found
    end
    nil
  end
end
