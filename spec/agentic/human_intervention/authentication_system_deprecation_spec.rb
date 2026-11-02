# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentic::HumanIntervention::AuthenticationSystem::Authenticator do
  it "emits a :deprecated warning pointing at issue #58" do
    expect(Warning).to receive(:warn)
      .with(a_string_including("AuthenticationSystem is deprecated", "issues/58"), category: :deprecated)

    previous = Warning[:deprecated]
    Warning[:deprecated] = true
    begin
      described_class.new
    ensure
      Warning[:deprecated] = previous
    end
  end
end
