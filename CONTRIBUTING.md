# Contributing to Agentic

Thank you for your interest in contributing to Agentic! This guide will help you get started with contributing to our AI agent orchestration framework.

## Quick Start

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/agentic.git
   cd agentic
   ```
3. **Set up development environment**:
   ```bash
   bin/setup
   ```
4. **Run tests** to ensure everything works:
   ```bash
   bundle exec rake
   ```

## Development Guidelines

### Code Standards

- **Ruby Style**: Follow [StandardRB](https://github.com/testdouble/standard) conventions
- **Testing**: Use RSpec for tests, aim for >90% coverage on new code
- **Documentation**: Use YARD comments for all public APIs
- **Commit Messages**: Follow [Conventional Commits](https://www.conventionalcommits.org/)
- **Dependencies**: If a change moves `Gemfile.lock` or the gemspec, check it for known advisories first:

  ```bash
  gem install bundler-audit -v '~> 0.9'
  bundler-audit check --update
  ```

  If your shell can't find `bundler-audit` after installing it, your gem bindir isn't on `PATH`; `gem exec bundler-audit check --update` works regardless on RubyGems 3.5+.

  CI runs the same command on those changes and again every Monday. If it flags an advisory in a gem your change did not touch, say so in the PR rather than bundling an unrelated upgrade into it. An advisory that genuinely cannot be fixed by an upgrade goes in `.bundler-audit.yml` with a reason and an exit condition, where CI honors it and a reviewer can see it.

### Before You Code

1. **Check existing issues** and discussions
2. **Open an issue** for significant changes to discuss approach
3. **Review architectural documentation**:
   - `ArchitectureConsiderations.md` - Overall system design
   - `ArchitecturalFeatureBuilder.md` - Implementation guidelines
   - `.architecture/principles.md` - Core architectural principles

### Architectural Guidelines

**Before implementing any feature**:

1. **Review Architecture**: Consult architectural documentation
2. **System Layer Identification**: Determine which layer(s) your feature affects:
   - Foundation Layer (core abstractions, registries)
   - Runtime Layer (task execution, orchestration)
   - Verification Layer (quality assurance, validation)
   - Extension System (plugins, domain adapters)
3. **Interface Design**: Define clear interfaces following established patterns
4. **Implementation Checklist**: Use the checklist in `ArchitecturalFeatureBuilder.md`

### Code Workflow

1. **Create a feature branch** from main:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Write tests first** (TDD approach encouraged):
   ```bash
   bundle exec rspec spec/path/to/new_feature_spec.rb
   ```

3. **Implement your feature** following our patterns:
   - Use dependency injection
   - Follow the Observable pattern for state changes
   - Implement proper error handling with detailed context
   - Add comprehensive logging

4. **Run the full test suite**:
   ```bash
   bundle exec rake
   ```

5. **Check code style**:
   ```bash
   bundle exec rake standard
   # Auto-fix style issues:
   standardrb --fix
   ```

6. **Update documentation** as needed

## Testing Guidelines

### Test Structure

- **Unit Tests**: Test individual classes and methods
- **Integration Tests**: Test component interactions
- **Feature Tests**: Test end-to-end workflows

### VCR Cassettes

The project uses VCR to record HTTP interactions. When adding new API calls:

1. **Record cassettes** during initial test runs
2. **Commit cassettes** with your changes
3. **Use descriptive cassette names** that relate to the test scenario

### Test Examples

```ruby
# spec/agentic/your_feature_spec.rb
require 'spec_helper'

RSpec.describe Agentic::YourFeature do
  describe '#method_name' do
    it 'does something useful' do
      # Arrange
      feature = described_class.new

      # Act
      result = feature.method_name

      # Assert
      expect(result).to be_successful
    end
  end
end
```

## Making Changes

### Types of Changes

- **Bug Fix**: Fix incorrect behavior
- **Enhancement**: Improve existing functionality
- **New Feature**: Add new capability
- **Breaking Change**: Modify public API (requires special care)

### For New Features

1. **Create an ADR** (Architectural Decision Record) for significant features:
   ```bash
   cp .architecture/templates/adr.md .architecture/decisions/adrs/ADR-XXX-your-feature.md
   ```

2. **Follow the feature implementation process** from `ArchitecturalFeatureBuilder.md`

3. **Add comprehensive tests** including edge cases

4. **Update documentation** including README if needed

### For Breaking Changes

1. **Discuss in an issue first** - breaking changes require community input
2. **Follow semantic versioning** - breaking changes increment major version
3. **Provide migration guide** in CHANGELOG.md
4. **Deprecate before removing** when possible

## Pull Request Process

### Before Submitting

- [ ] All tests pass: `bundle exec rake`
- [ ] Code follows style guide: `bundle exec rake standard`
- [ ] Documentation is updated
- [ ] CHANGELOG.md is updated (for user-facing changes)
- [ ] Commit messages follow conventional format

### PR Description Template

```markdown
## Summary
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] Enhancement
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] All tests pass locally

## Documentation
- [ ] Code comments updated
- [ ] README updated (if needed)
- [ ] CHANGELOG updated (if needed)
- [ ] ADR created (for significant changes)

## Additional Notes
Any additional context or considerations
```

### Review Process

1. **Automated checks** must pass (CI, linting, tests)
2. **Code review** by maintainers
3. **Architectural review** for significant changes
4. **Documentation review** for user-facing changes

## Release Process

### Version Strategy

- **Patch** (0.0.X): Bug fixes, documentation
- **Minor** (0.X.0): New features, non-breaking enhancements
- **Major** (X.0.0): Breaking changes

### Release Steps

1. Update `lib/agentic/version.rb`
2. Update `CHANGELOG.md`
3. Create release PR
4. Tag and release via `bundle exec rake release`

## Community Guidelines

### Communication

- **Be respectful** and inclusive
- **Ask questions** when you're unsure
- **Share knowledge** and help others
- **Give constructive feedback** in reviews

### Getting Help

- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: Questions and general discussion
- **Code Comments**: Implementation-specific questions

## Advanced Topics

### Extension Development

If you're developing plugins or extensions:

1. **Review extension patterns** in `lib/agentic/extension/`
2. **Follow plugin interfaces** defined in extension system
3. **Add comprehensive tests** for extension points
4. **Document extension API** changes

### Performance Considerations

- **Profile before optimizing** using Ruby profiling tools
- **Consider LLM API costs** in design decisions
- **Test performance impact** of changes
- **Use caching appropriately** following established patterns

### Security Considerations

- **Review security implications** of changes
- **Follow secure coding practices**
- **Consider content filtering** for user inputs
- **Implement appropriate permissions** for new capabilities

## Development Tools

### Useful Commands

```bash
# Run specific tests
bundle exec rspec spec/path/to/file_spec.rb

# Run tests with coverage
COVERAGE=true bundle exec rspec

# Generate documentation
bundle exec yard doc

# Interactive console with gem loaded
bundle exec rake console
```

### IDE Setup

The project includes configuration for:
- **VS Code**: `.vscode/` directory with recommended extensions
- **RuboCop**: For linting integration
- **YARD**: For documentation generation

## Questions?

If you have questions not covered in this guide:

1. **Check existing documentation** in the repository
2. **Search GitHub issues** for similar questions
3. **Open a GitHub Discussion** for general questions
4. **Open a GitHub Issue** for specific bugs or feature requests

Thank you for contributing to Agentic! 🚀