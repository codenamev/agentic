# frozen_string_literal: true

RSpec.describe Agentic::Security::SecureErrorMixin do
  before(:each) do
    # Configure security for testing
    Agentic::Security::Config.configure(
      sanitization_level: :standard,
      enable_pii_detection: true,
      log_security_events: true
    )
  end

  after(:each) do
    Agentic::Security::Config.reset!
  end

  # Test class that includes the mixin
  let(:test_error_class) do
    Class.new(StandardError) do
      include Agentic::Security::SecureErrorMixin

      attr_reader :context, :response

      def initialize(message, context: nil, response: nil)
        super(message)
        @context = context
        @response = response
      end
    end
  end

  describe "message sanitization" do
    it "sanitizes error messages containing PII" do
      error = test_error_class.new("Authentication failed for user john@example.com with key sk-123456")

      safe_message = error.safe_message
      expect(safe_message).to include("[REDACTED_EMAIL]", "[REDACTED_API_KEY]")
      expect(safe_message).not_to include("john@example.com", "sk-123456")
    end

    it "returns original message when PII detection is disabled" do
      Agentic::Security::Config.configure(enable_pii_detection: false)

      sensitive_message = "User email: sensitive@company.com"
      error = test_error_class.new(sensitive_message)

      expect(error.safe_message).to eq(sensitive_message)
    end
  end

  describe "context sanitization" do
    it "sanitizes error context containing sensitive data" do
      context = {
        user_email: "test@example.com",
        api_key: "secret-key-123",
        safe_data: "this is safe"
      }

      error = test_error_class.new("Error occurred", context: context)
      safe_context = error.safe_context

      expect(safe_context[:user_email]).to include("[REDACTED_EMAIL]")
      expect(safe_context[:api_key]).to include("[REDACTED_API_KEY]")
      expect(safe_context[:safe_data]).to eq("this is safe")
    end

    it "handles nil context gracefully" do
      error = test_error_class.new("Error without context")
      expect(error.safe_context).to be_nil
    end
  end

  describe "response sanitization" do
    it "sanitizes API response data" do
      response = {
        "user" => "admin@company.com",
        "token" => "bearer-abc123def456",
        "data" => "safe response data"
      }

      error = test_error_class.new("API error", response: response)
      safe_response = error.safe_response

      expect(safe_response["user"]).to include("[REDACTED_EMAIL]")
      expect(safe_response["token"]).to include("[REDACTED_API_KEY]")
      expect(safe_response["data"]).to eq("safe response data")
    end

    it "handles nil response gracefully" do
      error = test_error_class.new("Error without response")
      expect(error.safe_response).to be_nil
    end
  end

  describe "backtrace sanitization" do
    it "sanitizes backtrace when enabled" do
      Agentic::Security::Config.configure(backtrace_sanitization: true)

      error = test_error_class.new("Test error")
      error.set_backtrace([
        "/home/user/sensitive/path.rb:10:in `method'",
        "/app/lib/main.rb:5:in `run'",
        "/usr/local/api_key=secret123/file.rb:20"
      ])

      safe_backtrace = error.safe_backtrace
      expect(safe_backtrace).to be_an(Array)
      expect(safe_backtrace.join("\n")).to include("[REDACTED_PATH]")
    end

    it "returns original backtrace when sanitization is disabled" do
      Agentic::Security::Config.configure(backtrace_sanitization: false)

      error = test_error_class.new("Test error")
      original_backtrace = ["/home/user/path.rb:10", "/app/lib/main.rb:5"]
      error.set_backtrace(original_backtrace)

      expect(error.safe_backtrace).to eq(original_backtrace)
    end
  end

  describe "secure hash conversion" do
    it "creates secure hash representation" do
      error = test_error_class.new(
        "Error with PII: user@example.com",
        context: {api_key: "secret123"},
        response: {token: "bearer-xyz"}
      )

      secure_hash = error.to_secure_hash

      expect(secure_hash).to include(:class, :message, :timestamp, :context, :response)
      expect(secure_hash[:message]).to include("[REDACTED_EMAIL]")
      expect(secure_hash[:context][:api_key]).to include("[REDACTED_API_KEY]")
      expect(secure_hash[:response][:token]).to include("[REDACTED_API_KEY]")
      expect(secure_hash[:class]).to eq(error.class.name)
      expect(secure_hash[:timestamp]).to be_a(String)
    end

    it "includes backtrace in secure hash when configured" do
      Agentic::Security::Config.configure(backtrace_sanitization: true)

      error = test_error_class.new("Test error")
      error.set_backtrace(["/path1.rb:10", "/path2.rb:5"] * 10) # Long backtrace

      secure_hash = error.to_secure_hash

      expect(secure_hash).to include(:backtrace)
      expect(secure_hash[:backtrace]).to be_an(Array)
      expect(secure_hash[:backtrace].size).to be <= 10 # Limited to 10 entries
    end
  end

  describe "secure logging" do
    let(:mock_logger) { double("Logger") }

    before do
      allow(Agentic).to receive(:logger).and_return(mock_logger)
      # Config.configure emits an :info line; allow it so the specs can assert
      # only on the :error/:debug output produced by log_securely.
      allow(mock_logger).to receive(:info)
    end

    it "logs securely when security events are enabled" do
      Agentic::Security::Config.configure(log_security_events: true)

      expect(mock_logger).to receive(:error).with(/Secure Error Report/)
      expect(mock_logger).to receive(:error).with(/Message:.*REDACTED_EMAIL/)

      error = test_error_class.new("Error for user@example.com")
      error.log_securely
    end

    it "logs minimal information when security events are disabled" do
      Agentic::Security::Config.configure(log_security_events: false)

      expect(mock_logger).to receive(:error).with(/.*REDACTED_EMAIL/)

      error = test_error_class.new("Error for user@example.com")
      error.log_securely
    end

    it "logs context and backtrace in debug mode" do
      Agentic::Security::Config.configure(
        log_security_events: true,
        backtrace_sanitization: true
      )

      expect(mock_logger).to receive(:error).twice
      expect(mock_logger).to receive(:debug).with(/Context:/)
      expect(mock_logger).to receive(:debug).with(/Backtrace:/)

      error = test_error_class.new(
        "Test error",
        context: {key: "value"}
      )
      error.set_backtrace(["/path.rb:10"])
      error.log_securely
    end

    it "handles nil logger gracefully" do
      allow(Agentic).to receive(:logger).and_return(nil)

      error = test_error_class.new("Test error")
      expect { error.log_securely }.not_to raise_error
    end
  end

  describe "integration with LLM errors" do
    it "works with LlmError classes" do
      error = Agentic::Errors::LlmError.new(
        "Authentication failed for user@example.com",
        context: {api_key: "secret123"},
        response: {error: "Unauthorized", user: "admin@company.com"}
      )

      # The mixin should be included via the base error class
      expect(error).to respond_to(:safe_message)
      expect(error).to respond_to(:safe_context)
      expect(error).to respond_to(:safe_response)

      safe_message = error.safe_message
      expect(safe_message).to include("[REDACTED_EMAIL]")
      expect(safe_message).not_to include("user@example.com")
    end
  end

  describe "opt-in contract" do
    it "leaves #message, #to_s, and #inspect untouched" do
      raw = "Authentication failed for user@example.com with key sk-123456"
      error = Agentic::Errors::LlmError.new(raw, response: {"Authorization" => "Bearer sk-123456"})

      expect(error.message).to eq(raw)
      expect(error.to_s).to eq(raw)
      expect(error.inspect).to include("sk-123456")
      expect(error.response).to eq({"Authorization" => "Bearer sk-123456"})
    end

    it "does not add a class-level switch to includers" do
      expect(Agentic::Errors::LlmError).not_to respond_to(:secure_error_class!)
      expect(test_error_class).not_to respond_to(:secure_error_class!)
    end

    it "sanitizes only through the safe_* accessors" do
      error = Agentic::Errors::LlmError.new(
        "key sk-123456 leaked",
        response: {"Authorization" => "Bearer sk-123456"}
      )

      expect(error.safe_message).to eq("key [REDACTED_API_KEY] leaked")
      expect(error.safe_response.to_s).not_to include("sk-123456")
    end
  end

  describe "safe_message never raises" do
    it "scrubs invalid bytes before sanitizing" do
      bad = (+"key sk-123456 then \xFF\xFE").force_encoding("UTF-8")
      error = test_error_class.new(bad)

      expect { error.safe_message }.not_to raise_error
      expect(error.safe_message).to include("[REDACTED_API_KEY]")
      expect(error.safe_message).not_to include("sk-123456")
    end

    it "withholds the message when the sanitizer itself fails" do
      allow(Agentic::Security::Config.sanitizer).to receive(:sanitize_error).and_raise(RuntimeError, "boom")
      error = test_error_class.new("key sk-123456")

      expect(error.safe_message).to eq("[message withheld: sanitizer raised RuntimeError]")
      expect(error.safe_message).not_to include("sk-123456")
    end
  end

  describe "performance considerations" do
    it "handles large error contexts efficiently" do
      large_context = {}
      1000.times { |i| large_context["key_#{i}"] = "value_#{i}@example.com" }

      error = test_error_class.new("Large context error", context: large_context)

      start_time = Time.now
      safe_context = error.safe_context
      duration = Time.now - start_time

      expect(duration).to be < 1.0 # Should complete within 1 second
      expect(safe_context).to be_a(Hash)
    end

    it "caches sanitized values" do
      error = test_error_class.new("Error with user@example.com")

      # First call
      start_time = Time.now
      first_result = error.safe_message
      first_duration = Time.now - start_time

      # Second call (should use cached value)
      start_time = Time.now
      second_result = error.safe_message
      second_duration = Time.now - start_time

      expect(first_result).to eq(second_result)
      expect(second_duration).to be < first_duration
    end
  end
end
