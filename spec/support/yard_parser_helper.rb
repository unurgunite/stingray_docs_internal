# frozen_string_literal: true

module YardParserHelper
  def parse(string)
    Docscribe::Types::Yard.parse(string)
  end

  def to_rbs(node)
    Docscribe::Types::Yard::Formatter.to_rbs(node)
  end
end
