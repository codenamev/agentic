# frozen_string_literal: true

module Agentic
  module Capabilities
    # Example capabilities for common tasks
    module Examples
      class << self
        # Register all example capabilities
        # @return [void]
        def register_all
          register_text_generation
          register_web_search
          register_data_analysis
          register_code_generation
          register_summarization
          register_brainstorming
          register_structured_extraction
        end

        # Register a text generation capability
        # @return [CapabilitySpecification] The registered capability
        def register_text_generation
          spec = CapabilitySpecification.new(
            name: "text_generation",
            description: "Generates text based on a prompt",
            version: "1.0.0",
            inputs: {
              prompt: {
                type: "string",
                required: true,
                description: "The prompt to generate text from"
              },
              max_tokens: {
                type: "integer",
                description: "Maximum number of tokens to generate"
              },
              temperature: {
                type: "number",
                description: "Sampling temperature (0.0-1.0)"
              }
            },
            outputs: {
              response: {
                type: "string",
                required: true,
                description: "The generated text"
              }
            }
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              # Get the LLM client
              llm_config = LlmConfig.new
              llm_config.max_tokens = inputs[:max_tokens] if inputs[:max_tokens]
              llm_config.temperature = inputs[:temperature] if inputs[:temperature]

              client = Agentic.client(llm_config)

              # Generate text
              response = client.complete([{role: "user", content: inputs[:prompt]}])

              {response: response.content.to_s}
            end
          )

          registry.register(spec, provider)
        end

        # Register a web search capability
        # @return [CapabilitySpecification] The registered capability
        def register_web_search
          spec = CapabilitySpecification.new(
            name: "web_search",
            description: "Searches the web for information",
            version: "1.0.0",
            inputs: {
              query: {
                type: "string",
                required: true,
                description: "The search query"
              },
              num_results: {
                type: "integer",
                description: "Number of results to return"
              }
            },
            outputs: {
              results: {
                type: "array",
                required: true,
                description: "The search results"
              },
              sources: {
                type: "array",
                description: "The sources of the results"
              }
            }
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              # Delegates to the pluggable search backend (DuckDuckGo by
              # default; see Capabilities::WebSearch to configure your own)
              WebSearch.search(inputs[:query], num_results: inputs[:num_results] || 3)
            end
          )

          registry.register(spec, provider)
        end

        # Register a data analysis capability
        # @return [CapabilitySpecification] The registered capability
        def register_data_analysis
          spec = CapabilitySpecification.new(
            name: "data_analysis",
            description: "Analyzes data and extracts insights",
            version: "1.0.0",
            inputs: {
              data: {
                type: "object",
                required: true,
                description: "The data to analyze"
              },
              analysis_type: {
                type: "string",
                description: "The type of analysis to perform"
              }
            },
            outputs: {
              insights: {
                type: "array",
                required: true,
                description: "The extracted insights"
              },
              summary: {
                type: "string",
                required: true,
                description: "A summary of the analysis"
              }
            },
            dependencies: [
              {name: "text_generation", version: "1.0.0"}
            ]
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              data = inputs[:data]
              analysis_type = inputs[:analysis_type] || "basic"

              # Get the text generation capability
              text_gen_provider = registry.get_provider("text_generation")

              # Generate insights based on the data
              insights_prompt = "Analyze the following data using #{analysis_type} analysis and provide key insights:\n\n#{data.inspect}"
              insights_response = text_gen_provider.execute(prompt: insights_prompt)[:response]

              # Parse insights
              insights = insights_response.split("\n").map(&:strip).reject(&:empty?)

              # Generate summary
              summary_prompt = "Summarize the following insights in one paragraph:\n\n#{insights.join("\n")}"
              summary = text_gen_provider.execute(prompt: summary_prompt)[:response]

              {
                insights: insights,
                summary: summary
              }
            end
          )

          registry.register(spec, provider)
        end

        # Register a code generation capability
        # @return [CapabilitySpecification] The registered capability
        def register_code_generation
          spec = CapabilitySpecification.new(
            name: "code_generation",
            description: "Generates code based on requirements",
            version: "1.0.0",
            inputs: {
              requirements: {
                type: "string",
                required: true,
                description: "The code requirements"
              },
              language: {
                type: "string",
                required: true,
                description: "The programming language"
              },
              include_comments: {
                type: "boolean",
                description: "Whether to include comments in the code"
              }
            },
            outputs: {
              code: {
                type: "string",
                required: true,
                description: "The generated code"
              },
              explanation: {
                type: "string",
                description: "Explanation of the code"
              }
            },
            dependencies: [
              {name: "text_generation", version: "1.0.0"}
            ]
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              requirements = inputs[:requirements]
              language = inputs[:language]
              include_comments = inputs[:include_comments] || false

              # Get the text generation capability
              text_gen_provider = registry.get_provider("text_generation")

              # Generate code
              comments_instruction = include_comments ? "Include detailed comments." : "Keep comments minimal."
              code_prompt = "Generate #{language} code for the following requirements:\n\n#{requirements}\n\n#{comments_instruction}"
              code = text_gen_provider.execute(prompt: code_prompt)[:response]

              # Generate explanation if needed
              explanation = nil
              if include_comments
                explanation_prompt = "Explain the following #{language} code:\n\n#{code}"
                explanation = text_gen_provider.execute(prompt: explanation_prompt)[:response]
              end

              result = {code: code}
              result[:explanation] = explanation if explanation

              result
            end
          )

          registry.register(spec, provider)
        end

        # Register a summarization capability
        # @return [CapabilitySpecification] The registered capability
        def register_summarization
          spec = CapabilitySpecification.new(
            name: "summarization",
            description: "Summarizes text content",
            version: "1.0.0",
            inputs: {
              content: {
                type: "string",
                required: true,
                description: "The content to summarize"
              },
              max_length: {
                type: "integer",
                description: "Maximum length of the summary"
              },
              format: {
                type: "string",
                description: "Format of the summary (paragraph, bullets, etc.)"
              }
            },
            outputs: {
              summary: {
                type: "string",
                required: true,
                description: "The generated summary"
              },
              key_points: {
                type: "array",
                description: "Key points from the content"
              }
            },
            dependencies: [
              {name: "text_generation", version: "1.0.0"}
            ]
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              content = inputs[:content]
              max_length = inputs[:max_length]
              format = inputs[:format] || "paragraph"

              # Get the text generation capability
              text_gen_provider = registry.get_provider("text_generation")

              # Generate summary
              length_instruction = max_length ? "Keep the summary under #{max_length} words." : ""
              summary_prompt = "Summarize the following content in #{format} format. #{length_instruction}\n\n#{content}"
              summary = text_gen_provider.execute(prompt: summary_prompt)[:response]

              # Extract key points
              key_points_prompt = "Extract 3-5 key points from the following content:\n\n#{content}"
              key_points_response = text_gen_provider.execute(prompt: key_points_prompt)[:response]
              key_points = key_points_response.split("\n").map(&:strip).reject(&:empty?)

              {
                summary: summary,
                key_points: key_points
              }
            end
          )

          registry.register(spec, provider)
        end

        # Register a brainstorming capability
        # @return [CapabilitySpecification] The registered capability
        def register_brainstorming
          spec = CapabilitySpecification.new(
            name: "brainstorming",
            description: "Generates creative ideas for a topic",
            version: "1.0.0",
            inputs: {
              topic: {
                type: "string",
                required: true,
                description: "The topic to brainstorm about"
              },
              num_ideas: {
                type: "integer",
                description: "Number of ideas to generate"
              },
              creativity: {
                type: "number",
                description: "Creativity level (0.0-1.0)"
              }
            },
            outputs: {
              ideas: {
                type: "array",
                required: true,
                description: "The generated ideas"
              },
              themes: {
                type: "array",
                description: "Common themes across the ideas"
              }
            },
            dependencies: [
              {name: "text_generation", version: "1.0.0"}
            ]
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              topic = inputs[:topic]
              num_ideas = inputs[:num_ideas] || 10
              creativity = inputs[:creativity] || 0.7

              # Get the text generation capability
              text_gen_provider = registry.get_provider("text_generation")

              # Generate ideas
              ideas_prompt = "Brainstorm #{num_ideas} creative ideas about: #{topic}"
              ideas_response = text_gen_provider.execute(
                prompt: ideas_prompt,
                temperature: creativity
              )[:response]

              # Parse ideas
              ideas = ideas_response.split("\n").map { |line| line.sub(/^\d+\.\s*/, "") }.map(&:strip).reject(&:empty?)

              # Identify themes
              themes_prompt = "Identify 3-5 common themes in the following ideas:\n\n#{ideas.join("\n")}"
              themes_response = text_gen_provider.execute(prompt: themes_prompt)[:response]
              themes = themes_response.split("\n").map(&:strip).reject(&:empty?)

              {
                ideas: ideas,
                themes: themes
              }
            end
          )

          registry.register(spec, provider)
        end

        # Register a structured extraction capability
        # @return [CapabilitySpecification] The registered capability
        def register_structured_extraction
          spec = CapabilitySpecification.new(
            name: "structured_extraction",
            description: "Extracts structured data from text",
            version: "1.0.0",
            inputs: {
              content: {
                type: "string",
                required: true,
                description: "The content to extract from"
              },
              schema: {
                type: "object",
                required: true,
                description: "The schema to extract"
              }
            },
            outputs: {
              data: {
                type: "object",
                required: true,
                description: "The extracted data"
              },
              confidence: {
                type: "number",
                description: "Confidence score for the extraction"
              }
            },
            dependencies: [
              {name: "text_generation", version: "1.0.0"}
            ]
          )

          provider = CapabilityProvider.new(
            capability: spec,
            implementation: lambda do |inputs|
              content = inputs[:content]
              schema = inputs[:schema]

              # Get the text generation capability
              text_gen_provider = registry.get_provider("text_generation")

              # Create extraction prompt
              schema_str = JSON.pretty_generate(schema)
              extraction_prompt = <<-PROMPT
              Extract structured data from the following content according to this schema:
              
              #{schema_str}
              
              Content:
              #{content}
              
              Return the data as valid JSON.
              PROMPT

              # Generate extraction
              extraction_response = text_gen_provider.execute(prompt: extraction_prompt)[:response]

              # Parse JSON (with error handling)
              data = nil
              begin
                # Clean the response to ensure it's valid JSON
                json_str = extraction_response.gsub(/```json|```/, "").strip
                data = JSON.parse(json_str)
              rescue JSON::ParserError
                # Fallback extraction for malformed JSON
                data = extract_fallback(extraction_response)
              end

              # Calculate confidence based on schema match
              confidence = calculate_confidence(data, schema)

              {
                data: data,
                confidence: confidence
              }
            end
          )

          registry.register(spec, provider)
        end

        private

        def registry
          AgentCapabilityRegistry.instance
        end

        # Fallback extraction for malformed JSON
        def extract_fallback(text)
          result = {}

          # Try to extract key-value pairs
          text.scan(/["']?([^"':]+)["']?\s*:\s*["']?([^"',}]+)["']?/) do |key, value|
            result[key.strip] = value.strip
          end

          result
        end

        # Calculate confidence based on schema match
        def calculate_confidence(data, schema)
          return 0.0 if data.nil?

          # Count matching fields
          matches = 0
          total = 0

          schema.each do |key, _|
            total += 1
            matches += 1 if data.key?(key.to_s) || data.key?(key.to_sym)
          end

          (total > 0) ? matches.to_f / total : 0.0
        end
      end
    end
  end
end
