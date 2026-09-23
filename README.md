<h1 align="center">Furud</h1>

<p align="center">
  <strong>A dependency-free Ruby spreadsheet formula and recalculation engine</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/furud"><img src="https://img.shields.io/gem/v/furud.svg?colorB=319e8c" alt="Gem version"></a>
  <a href="https://github.com/noxdea/furud/actions/workflows/main.yml"><img src="https://github.com/noxdea/furud/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D.svg" alt="Ruby 3.2 or newer">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

Furud parses and evaluates spreadsheet formulas without owning cell storage or a UI. It maintains cell dependencies, recalculates only affected formulas, reports cycles, translates A1/R1C1 references, spills array results, and formats numbers and dates. Runtime code uses Ruby's standard library only.

## Install

```ruby
gem "furud"
```

Furud requires Ruby 3.2 or newer.

## Quick start

```ruby
require "furud"

source = {
  ["Sales", 1, 1] => 12,
  ["Sales", 2, 1] => 30
}
engine = Furud::Engine.new(source)
total = Furud::Reference.new(sheet: "Sales", row: 1, column: 2)

engine.set(total, "=SUM(A1:A2)")
engine.value(total) # => 42
engine.formula(total) # => "=SUM(A1:A2)"
```

Rows and columns are one-based. A source is any object with `value_at(reference)` and optionally `each_in(area) { |reference, value| }`; a storage library can therefore provide sparse range iteration without becoming a Furud dependency. A plain Hash keyed by `[sheet, row, column]` or `Reference` also works.

`set` accepts a formula string beginning with `=` or a raw Ruby value. `value` recalculates pending work before returning a value. `recalculate` returns cells whose values changed; `dirty`, `precedents`, and `dependents` expose pending work and dependency traces. `clear` removes a cell. `define_name` accepts a `Reference` or `Area`.

## Formulas and references

```ruby
origin = Furud::Reference.new(sheet: "Sales", row: 5, column: 2)
ast = Furud::Formula.parse("=SUM('Annual Plan'!$A$1:B2)+R[1]C[-1]", origin: origin)
Furud::Formula.render(ast, origin: origin) # => "=SUM('Annual Plan'!$A$1:B2)+A6"
Furud::Formula.references(ast) # => [an Area, a Reference]

copied = Furud::Formula.translate(ast, from: origin, to: Furud::Reference.new(sheet: "Sales", row: 5, column: 3))
adjusted = Furud::Formula.adjust(ast, type: :insert_rows, sheet: "Sales", at: 2, count: 1)
```

The parser supports A1 and R1C1 cell references, absolute and relative markers, quoted sheet names, cell ranges, named ranges, arrays, Excel-style operator precedence, comparison and concatenation operators, errors, unary signs, percentages, and function calls. Unqualified references resolve against the formula's origin sheet. Parse failures raise `Furud::ParseError`; they are not silently evaluated as partial formulas.

`Engine#insert_rows`, `#delete_rows`, `#insert_columns`, and `#delete_columns` adjust formulas and move cells stored by the engine. The host remains responsible for applying the same structural edit to its own source storage.

## Calculation and functions

The default registry contains 191 functions across arithmetic, statistics, logic, text, dates, lookup/information, and basic finance. It is extensible:

```ruby
functions = Furud::Functions.standard
functions.register("DOUBLE", arity: 1) { |number| number * 2 }
engine = Furud::Engine.new(source, functions: functions)
```

The function count describes registered names, not complete Excel compatibility. Advanced statistical and financial edge cases, some date/lookup modes, and Excel's full argument-coercion rules are not exhaustive; `INDIRECT` currently parses A1 references only and does not implement its R1C1 mode.

Formula errors are values: `#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`, `#N/A`, `#NUM!`, and `#CYCLE!` (plus `#SPILL!` for occupied array spill areas). Errors propagate through calculations; `IF`, `IFERROR`, and `IFNA` evaluate only the selected branch. `iterative: true` enables bounded fixed-point evaluation for circular formulas.

Array constants and dynamic-array functions such as `SEQUENCE`, `TRANSPOSE`, and `UNIQUE` return a top-left value and spill into adjacent empty cells. Furud never overwrites non-empty cells; a blocked spill returns `#SPILL!`.

Array support is an MVP subset: rectangular constants, scalar broadcasting, and selected functions (`SEQUENCE`, `SORT`, `TRANSPOSE`, `UNIQUE`) are supported; `FILTER` and full spreadsheet dynamic-array semantics are not.

## Number formats

```ruby
spec = Furud::Format.parse("#,##0.00;[Red](#,##0.00)")
Furud::Format.apply(-1234.5, spec) # => ["(1,234.50)", { section: 1, color: :red }]
Furud::Format.apply(Date.new(2026, 9, 23), Furud::Format.parse("yyyy/mm/dd"))
# => ["2026/09/23", { section: 0 }]

Furud::Format.infer("12,5", locale: :de) # => [12.5, "0.00"]
```

Common numeric/date tokens, up to four sections, positive/negative/zero/text selection, simple numeric conditions, named colors, decimal/grouping locale marks, percentages, and quoted literals are supported. This is a formatting engine for spreadsheet display, not an XLSX compatibility layer; unsupported Excel format directives are preserved as literal text where possible.

## Development

```sh
bundle install
bundle exec rake
bundle exec rbs -I sig validate
bundle exec rake bench
```

`BUDGET=1 bundle exec rake bench` checks the 100,000-formula workload against the 10 ms incremental and 3 second full-recalculation budgets. See [architecture decisions](docs/adr/README.md).
