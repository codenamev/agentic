# frozen_string_literal: true

# The One-File API: an endpoint is a contract wearing HTTP. Declare
# the capability once and the rest is derived - the 422s (with
# relation rules explained), the 201, and the machine-readable schema
# your client generator reads. No serializer classes, no validator
# classes, no docs pipeline. One declaration, three doors.
#
#   bundle exec ruby examples/one_file_api.rb
#
# Runs offline; requests are simulated, responses are real.

require_relative "../lib/agentic"
require "json"

QUOTES = Agentic::CapabilitySpecification.new(
  name: "quotes", description: "Quote a shipment", version: "3.0.0",
  inputs: {
    mode: {type: "string", required: true, enum: %w[air sea road]},
    weight: {type: "number", required: true, min: 1, max: 5_000},
    volume: {type: "number", min: 0},
    express: {type: "boolean"},
    customs_code: {type: "string"}
  },
  outputs: {price_cents: {type: "number", required: true}},
  rules: {
    fits: {relation: :sum_lte, fields: [:weight, :volume], limit: 6_000},
    customs: {relation: :requires, fields: [:express, :customs_code]}
  }
)

RATES = {"air" => 9, "sea" => 2, "road" => 4}.freeze

# The entire app. Everything else in this file is derived from QUOTES.
def create_quote(params)
  {price_cents: (params[:weight] * RATES[params[:mode]] * (params[:express] ? 2 : 1)).round}
end

# --- the derived API layer -----------------------------------------------------
def handle(method, path, body = nil)
  case [method, path]
  in ["GET", "/quotes/schema"]
    [200, QUOTES.to_json_schema]
  in ["POST", "/quotes"]
    validator = Agentic::CapabilityValidator.new(QUOTES)
    begin
      params = body.transform_keys(&:to_sym)
      validator.validate_inputs!(params)
      output = create_quote(params)
      validator.validate_outputs!(output) # the contract guards BOTH doors
      [201, output]
    rescue Agentic::Errors::ValidationError => e
      errors = e.violations.except(:base).map { |field, messages| {field: field, errors: messages} }
      errors += e.rule_violations.map { |v| {rule: v[:rule], fields: v[:fields], error: v[:message]} }
      [422, {errors: errors}]
    end
  else
    [404, {error: "no such route"}]
  end
end

REQUESTS = [
  ["GET", "/quotes/schema", nil],
  ["POST", "/quotes", {"mode" => "teleport", "weight" => 9_000}],
  ["POST", "/quotes", {"mode" => "air", "weight" => 4_000, "volume" => 3_000}],
  ["POST", "/quotes", {"mode" => "air", "weight" => 100, "express" => true}],
  ["POST", "/quotes", {"mode" => "air", "weight" => 100, "express" => true, "customs_code" => "HS-42"}]
].freeze

puts "THE ONE-FILE API (#{QUOTES.name} v#{QUOTES.version})"
puts
REQUESTS.each do |method, path, body|
  status, response = handle(method, path, body)
  puts "  #{method} #{path}#{" #{JSON.generate(body)}" if body}"
  rendered = JSON.generate(response)
  rendered = "#{rendered[0, 100]}... (#{rendered.size} bytes)" if rendered.size > 110
  puts "    -> #{status} #{rendered}"
  puts
end

schema = QUOTES.to_json_schema
puts "  count what you didn't write: the 422 renderer never mentions a"
puts "  field name, the schema endpoint is one method call, and the"
puts "  relation rules flow to BOTH doors - the 422 explains"
puts "  \"#{QUOTES.rules[:customs][:fields].first} requires #{QUOTES.rules[:customs][:fields].last}\" to humans, while the schema's"
puts "  dependencies clause (#{JSON.generate(schema["dependencies"])}) tells"
puts "  client generators the same law in draft-07. one declaration,"
puts "  and the API layer is just... reading it. the best code in your"
puts "  app is the code that isn't there."
