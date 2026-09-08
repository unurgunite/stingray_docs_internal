# frozen_string_literal: true

module RbsTypeFormatterHelper
  def yard(type)
    Docscribe::Types::RBS::TypeFormatter.to_yard(type)
  end

  def type_name(str)
    RBS::TypeName.parse(str)
  end

  def yard_cog(type, collapse_object_generics: false)
    Docscribe::Types::RBS::TypeFormatter.to_yard(type, collapse_object_generics: collapse_object_generics)
  end
end
