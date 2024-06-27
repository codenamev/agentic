# Agentic

A simple Ruby command-line tool to build and run AI Agents in a [plan-and-execute](https://blog.langchain.dev/planning-agents/#plan-and-execute) fashion.

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add agentic

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install agentic

# Agentic

A simple Ruby command-line tool to build and run AI Agents in a [plan-and-execute](https://blog.langchain.dev/planning-agents/#plan-and-execute) fashion.

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add agentic

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install agentic

## Usage

To use the TaskPlanner:

1. Require the gem:
   ```ruby
   require 'agentic'
   ```

2. Configure your OpenAI API key:
   ```ruby
   Agentic.configure do |config|
     config.access_token = 'your_openai_api_key'
   end
   ```

3. Create a TaskPlanner instance with a goal:
   ```ruby
   planner = Agentic::TaskPlanner.new("Write a blog post about Ruby on Rails")
   ```

4. Generate and display the plan:
   ```ruby
   plan = planner.plan
   puts plan
   ```

This will output a structured plan for accomplishing your goal, including tasks and expected output format.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/codenamev/agentic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/codenamev/agentic/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Agentic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/codenamev/agentic/blob/main/CODE_OF_CONDUCT.md).
