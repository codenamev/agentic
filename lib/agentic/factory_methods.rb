# frozen_string_literal: true

module Agentic
  module FactoryMethods
    def self.included(base)
      base.extend(ClassMethods)
      base.instance_variable_set(:@configurable_attributes, Set.new)
      base.instance_variable_set(:@assembly_instructions, Set.new)
    end

    module ClassMethods
      def build
        agent = new
        yield(agent) if block_given?
        configure(agent)
        run_assembly_instructions(agent)
        agent
      end

      private

      def configure(agent)
        configurable_attributes.each do |attr|
          agent.public_send(:"#{attr}=", nil) unless agent.public_send(attr)
        end
      end

      def run_assembly_instructions(agent)
        assembly_instructions.each do |instruction|
          instruction.call(agent)
        end
      end

      def configurable(*attrs)
        @configurable_attributes.merge(attrs)
        attr_accessor(*attrs)
      end

      def assembly(&block)
        @assembly_instructions << block
      end

      def configurable_attributes
        @configurable_attributes
      end

      def assembly_instructions
        @assembly_instructions
      end
    end
  end
end
