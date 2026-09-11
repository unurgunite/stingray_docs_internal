# frozen_string_literal: true

module CheckForCommentsHelper
  def resolve_config(raw, param_doc)
    instance_double(Docscribe::Config, raw: raw, param_documentation: param_doc)
  end
end
