# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task(:bench) do
  ruby "-Ilib", "bench/engine.rb"
end

task(:boundary) do
  files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] + ["furud.gemspec"] }
  violations = files.select { |path| File.read(File.join(__dir__, path)).match?(/denebola|zaniah|rukbat/i) }
  abort "Dependency boundary violation: #{violations.join(', ')}" unless violations.empty?
end

task default: %i[spec boundary]
