# lib/agentic/logger.rb
# frozen_string_literal: true

require "logger"

module Agentic
  class Logger < ::Logger
    COLORS = {
      "FATAL" => :red,
      "ERROR" => :red,
      "WARN" => :orange,
      "INFO" => :yellow,
      "DEBUG" => :white
    }

    # Simple formatter which only displays the message.
    class SimpleFormatter < ::Logger::Formatter
      # This method is invoked when a log event occurs
      def call(severity, timestamp, progname, msg)
        if $stdout.tty? && severity.respond_to?(:colorize)
          "#{severity.colorize(COLORS[severity])}: #{(String === msg) ? msg : msg.inspect}\n"
        else
          "#{severity}: #{(String === msg) ? msg : msg.inspect}\n"
        end
      end
    end

    def initialize(*args)
      super
      @formatter = SimpleFormatter < ::Logger::Formatter
    end

    def self.info(message)
      instance.info(message)
    end

    def self.error(message)
      instance.error(message)
    end

    def self.debug(message)
      instance.debug(message)
    end
  end
end
