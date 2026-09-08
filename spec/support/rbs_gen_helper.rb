# frozen_string_literal: true

module RbsGenHelper
  def t(**kwargs)
    described_class::YardTags.new(**kwargs)
  end

  def p(**kwargs)
    described_class::ParamTag.new(**kwargs)
  end

  def d(**kwargs)
    described_class::MethodDef.new(**kwargs)
  end
end
