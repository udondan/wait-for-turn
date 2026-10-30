# frozen_string_literal: true

# Read by bashcov. Only wait.sh counts: bats, the fake gh and the test
# helpers are traced too, but they are not what is being tested.
require "simplecov-cobertura"

# bashcov calls SimpleCov.start itself.
SimpleCov.configure do
  root __dir__
  coverage_dir "coverage"
  skip { |file| file.filename != File.join(__dir__, "wait.sh") }
  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter
  ])
end
