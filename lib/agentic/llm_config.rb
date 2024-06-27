# frozen_string_literal: true

module Agentic
  class LlmConfig
    attr_accessor :model

    def initialize(model: "gpt-4o-2024-08-06")
      @model = model
    end
  end
end
