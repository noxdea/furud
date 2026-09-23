# frozen_string_literal: true

require "furud"

def elapsed
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

groups = Integer(ENV.fetch("FURUD_BENCH_GROUPS", "2000"))
depth = 50
engine = Furud::Engine.new

groups.times do |group|
  row = group + 1
  base = Furud::Reference.new(sheet: nil, row: row, column: 1)
  engine.set(base, 1)
  1.upto(depth) do |step|
    column = step + 1
    previous = Furud::Formula.column_name(column - 1)
    reference = Furud::Reference.new(sheet: nil, row: row, column: column)
    engine.set(reference, "=$A#{row}+#{previous}#{row}")
  end
end

full_seconds = elapsed { engine.recalculate }
change = Furud::Reference.new(sheet: nil, row: 1, column: 1)
engine.set(change, 2)
incremental_seconds = elapsed { engine.recalculate }

puts format("cells=%d full=%.3fs one-cell=%.3fms", groups * depth, full_seconds, incremental_seconds * 1000)
if ENV["BUDGET"] == "1" && (full_seconds > 3.0 || incremental_seconds > 0.010)
  abort "performance budget exceeded (3.000s full, 10.000ms incremental)"
end
