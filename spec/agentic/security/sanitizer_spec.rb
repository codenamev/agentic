# frozen_string_literal: true

RSpec.describe Agentic::Security::Sanitizer do
  let(:sanitizer) { described_class.new }

  describe "initialization" do
    it "creates sanitizer with default configuration" do
      expect(sanitizer.security_level).to eq(described_class::SECURITY_LEVEL_STANDARD)
      expect(sanitizer.statistics).to include(:security_level, :active_pattern_types)
    end

    it "accepts custom security level" do
      strict_sanitizer = described_class.new(security_level: described_class::SECURITY_LEVEL_STRICT)
      expect(strict_sanitizer.security_level).to eq(described_class::SECURITY_LEVEL_STRICT)
    end

    it "accepts custom patterns and replacements" do
      custom_sanitizer = described_class.new(
        custom_patterns: {custom: [/test_pattern/]},
        replacements: {custom: "[CUSTOM_REDACTED]"}
      )

      expect(custom_sanitizer.custom_patterns).to eq({custom: [/test_pattern/]})
      expect(custom_sanitizer.replacements[:custom]).to eq("[CUSTOM_REDACTED]")
    end
  end

  describe "PII detection and sanitization" do
    context "API keys and tokens" do
      it "detects and sanitizes API keys" do
        sensitive_text = "api_key=sk-1234567890abcdef Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
        sanitized = sanitizer.sanitize(sensitive_text)

        expect(sanitized).to include("[REDACTED_API_KEY]")
        expect(sanitized).not_to include("sk-1234567890abcdef")
        expect(sanitized).not_to include("eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9")
      end

      it "handles various API key formats" do
        test_cases = [
          "SECRET=abcdef123456789",
          "token: ghijkl987654321",
          "password='mnopqr555666777'",
          "Bearer abcd1234efgh5678ijkl9012"
        ]

        test_cases.each do |test_case|
          sanitized = sanitizer.sanitize(test_case)
          expect(sanitized).to include("[REDACTED_API_KEY]")
          expect(sanitized).not_to include(test_case.match(/[a-zA-Z0-9]{8,}/).to_s) if /[a-zA-Z0-9]{8,}/.match?(test_case)
        end
      end
    end

    context "email addresses" do
      it "sanitizes email addresses" do
        text_with_email = "User email is john.doe@example.com for notifications"
        sanitized = sanitizer.sanitize(text_with_email)

        expect(sanitized).to include("[REDACTED_EMAIL]")
        expect(sanitized).not_to include("john.doe@example.com")
      end

      it "handles multiple email formats" do
        emails = [
          "simple@example.com",
          "user.name+tag@domain.co.uk",
          "test_email123@subdomain.example.org"
        ]

        emails.each do |email|
          text = "Contact: #{email}"
          sanitized = sanitizer.sanitize(text)
          expect(sanitized).to include("[REDACTED_EMAIL]")
          expect(sanitized).not_to include(email)
        end
      end
    end

    context "phone numbers" do
      it "leaves UUIDs intact even when their digit groups look like a phone number" do
        # 2nd + 3rd groups all-digit: matched the loose phone pattern before the guard
        uuid = "73fb9a6e-9973-4748-87aa-3aeaa0c29af2"
        text = "Dependency #{uuid} failed; call 555-123-4567"
        sanitized = sanitizer.sanitize(text)

        expect(sanitized).to include(uuid)
        expect(sanitized).to include("[REDACTED_PHONE]")
        expect(sanitized).not_to include("555-123-4567")
        expect(sanitizer.sanitize({dependency_id: uuid})[:dependency_id]).to eq(uuid)
      end

      it "sanitizes phone numbers" do
        text_with_phone = "Call me at 555-123-4567 or (555) 987-6543"
        sanitized = sanitizer.sanitize(text_with_phone)

        expect(sanitized).to include("[REDACTED_PHONE]")
        expect(sanitized).not_to include("555-123-4567")
        expect(sanitized).not_to include("(555) 987-6543")
      end
    end

    context "social security numbers" do
      it "sanitizes SSNs" do
        text_with_ssn = "SSN: 123-45-6789 for identity verification"
        sanitized = sanitizer.sanitize(text_with_ssn)

        expect(sanitized).to include("[REDACTED_SSN]")
        expect(sanitized).not_to include("123-45-6789")
      end
    end

    context "credit card numbers" do
      it "sanitizes credit card numbers" do
        text_with_cc = "Card number 4111111111111111 expires 12/25"
        sanitized = sanitizer.sanitize(text_with_cc)

        expect(sanitized).to include("[REDACTED_CARD]")
        expect(sanitized).not_to include("4111111111111111")
      end
    end
  end

  describe "security levels" do
    context "SECURITY_LEVEL_NONE" do
      let(:none_sanitizer) { described_class.new(security_level: described_class::SECURITY_LEVEL_NONE) }

      it "does not sanitize anything" do
        sensitive_text = "api_key=secret123 john@example.com 555-1234"
        sanitized = none_sanitizer.sanitize(sensitive_text)

        expect(sanitized).to eq(sensitive_text)
      end
    end

    context "SECURITY_LEVEL_BASIC" do
      let(:basic_sanitizer) { described_class.new(security_level: described_class::SECURITY_LEVEL_BASIC) }

      it "sanitizes basic PII patterns" do
        text = "api_key=secret123 john@example.com 555-1234 123-45-6789"
        sanitized = basic_sanitizer.sanitize(text)

        # Should sanitize API keys, emails, and phone numbers
        expect(sanitized).to include("[REDACTED_API_KEY]", "[REDACTED_EMAIL]", "[REDACTED_PHONE]")
        # Should not sanitize SSN at basic level (but our test SSN might match phone pattern)
      end
    end

    context "SECURITY_LEVEL_STRICT" do
      let(:strict_sanitizer) { described_class.new(security_level: described_class::SECURITY_LEVEL_STRICT) }

      it "sanitizes additional patterns including IP addresses" do
        text = "Server at 192.168.1.100 has file /home/user/secret/config.txt"
        sanitized = strict_sanitizer.sanitize(text)

        expect(sanitized).to include("[REDACTED_IP]", "[REDACTED_PATH]")
        expect(sanitized).not_to include("192.168.1.100")
      end
    end
  end

  describe "context-aware sanitization" do
    it "sanitizes error context differently" do
      error_data = {
        message: "Authentication failed for user john@example.com",
        backtrace: ["/home/user/app/lib/auth.rb:42", "/home/user/app/lib/main.rb:15"]
      }

      sanitized = sanitizer.sanitize(error_data, context: :error)

      expect(sanitized[:message]).to include("[REDACTED_EMAIL]")
      expect(sanitized[:backtrace]).to be_an(Array)
    end

    it "sanitizes API responses more aggressively" do
      api_response = {
        "user_email" => "test@example.com",
        "api_key" => "sk-1234567890",
        "data" => "safe content"
      }

      sanitized = sanitizer.sanitize_api_response(api_response)

      expect(sanitized).not_to include("test@example.com")
      expect(sanitized).not_to include("sk-1234567890")
      expect(sanitized["data"]).to eq("safe content")
    end

    it "sanitizes LLM content with truncation" do
      llm_content = {
        "messages" => "User input: my email is sensitive@company.com " * 20,
        "model" => "gpt-4",
        "api_key" => "secret-key-12345"
      }

      sanitized = sanitizer.sanitize_llm_content(llm_content)

      expect(sanitized["messages"]).to include("[REDACTED_EMAIL]")
      expect(sanitized["messages"]).to include("[TRUNCATED]")
      expect(sanitized["api_key"]).to eq("[REDACTED_AUTH]")
      expect(sanitized["model"]).to eq("gpt-4")
    end
  end

  describe "error sanitization" do
    it "sanitizes error messages" do
      error = StandardError.new("Failed to authenticate user@example.com with key sk-123456")
      sanitized = sanitizer.sanitize_error(error)

      expect(sanitized).to include("[REDACTED_EMAIL]", "[REDACTED_API_KEY]")
      expect(sanitized).not_to include("user@example.com", "sk-123456")
    end

    it "includes sanitized backtrace when requested" do
      error = StandardError.new("PII error john@test.com")
      error.set_backtrace(["/home/user/sensitive/path.rb:10", "/app/lib/main.rb:5"])

      sanitized = sanitizer.sanitize_error(error, include_backtrace: true)

      expect(sanitized).to include("[REDACTED_EMAIL]")
      expect(sanitized).to include("Backtrace:")
    end
  end

  describe "performance" do
    it "caches sanitization results" do
      text = "api_key=test123456789"

      # First sanitization
      start_time = Time.now
      result1 = sanitizer.sanitize(text)
      first_duration = Time.now - start_time

      # Second sanitization (should be cached)
      start_time = Time.now
      result2 = sanitizer.sanitize(text)
      second_duration = Time.now - start_time

      expect(result1).to eq(result2)
      expect(second_duration).to be < first_duration
    end

    it "handles large content efficiently" do
      large_text = "api_key=secret123 " * 1000

      start_time = Time.now
      sanitized = sanitizer.sanitize(large_text)
      duration = Time.now - start_time

      expect(duration).to be < 1.0 # Should complete within 1 second
      expect(sanitized).to include("[REDACTED_API_KEY]")
    end
  end

  describe "sensitive content detection" do
    it "identifies potentially sensitive content" do
      sensitive_texts = [
        "api_key=secret123",
        "User email: john@example.com",
        "Phone: 555-1234",
        "SSN: 123-45-6789"
      ]

      safe_texts = [
        "Hello world",
        "The weather is nice today",
        "Process completed successfully"
      ]

      sensitive_texts.each do |text|
        expect(sanitizer.potentially_sensitive?(text)).to be true
      end

      safe_texts.each do |text|
        expect(sanitizer.potentially_sensitive?(text)).to be false
      end
    end
  end

  describe "complex data structures" do
    it "sanitizes nested hash structures" do
      complex_data = {
        user: {
          name: "John Doe",
          email: "john@example.com",
          contact: {
            phone: "555-1234",
            address: "123 Main St"
          }
        },
        auth: {
          api_key: "sk-1234567890",
          token: "bearer-token-abc123"
        }
      }

      sanitized = sanitizer.sanitize(complex_data)

      expect(sanitized[:user][:email]).to include("[REDACTED_EMAIL]")
      expect(sanitized[:user][:contact][:phone]).to include("[REDACTED_PHONE]")
      expect(sanitized[:auth][:api_key]).to include("[REDACTED_API_KEY]")
      expect(sanitized[:user][:name]).to eq("John Doe") # Name should remain
      expect(sanitized[:user][:contact][:address]).to eq("123 Main St") # Address should remain at standard level
    end

    it "sanitizes arrays of mixed content" do
      array_data = [
        "Safe message",
        "Error: Authentication failed for user@example.com",
        {api_key: "secret123", data: "safe data"},
        ["nested", "array", "with", "phone: 555-9876"]
      ]

      sanitized = sanitizer.sanitize(array_data)

      expect(sanitized[0]).to eq("Safe message")
      expect(sanitized[1]).to include("[REDACTED_EMAIL]")
      expect(sanitized[2][:api_key]).to include("[REDACTED_API_KEY]")
      expect(sanitized[3][3]).to include("[REDACTED_PHONE]")
    end
  end
end
