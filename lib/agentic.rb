# frozen_string_literal: true

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

module Agentic
  class Error < StandardError; end

  class << self
    attr_accessor :logger
  end

  self.logger ||= Logger.new($stdout, level: :debug)

  class Configuration
    attr_accessor :access_token

    def initialize
      @access_token = ENV["OPENAI_ACCESS_TOKEN"]
    end
  end

  class << self
    attr_writer :configuration
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.configure
    yield(configuration)
  end

  def self.client(config)
    LlmClient.new(config)
  end
end
