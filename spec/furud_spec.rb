# frozen_string_literal: true

RSpec.describe Furud do
  def ref(row, column, sheet: nil)
    Furud::Reference.new(sheet: sheet, row: row, column: column)
  end

  let(:origin) { ref(2, 2, sheet: "Budget") }

  it "has a version number" do
    expect(Furud::VERSION).to eq("0.1.0")
  end

  describe Furud::Formula do
    it "parses Excel operator precedence and renders formulas" do
      ast = described_class.parse("=1+2*3^2", origin: origin)
      expect(described_class.render(ast, origin: origin)).to eq("=1+2*3^2")

      engine = Furud::Engine.new
      engine.set(origin, "=1+2*3^2")
      expect(engine.value(origin)).to eq(19)

      engine.set(origin, "=1/2")
      expect(engine.value(origin)).to eq(0.5)
      engine.set(origin, "=1/0")
      expect(engine.value(origin)).to eq(Furud::ErrorValue.new(code: :div0))
    end

    it "supports A1, quoted sheet, and R1C1 references" do
      ast = described_class.parse("=SUM('Annual Plan'!$A$1:B2)+R[1]C[-1]", origin: origin)
      expect(described_class.render(ast, origin: origin)).to eq("=SUM('Annual Plan'!$A$1:B2)+A3")
      expect(described_class.references(ast)).to include(
        Furud::Area.new(sheet: "Annual Plan", top: 1, left: 1, bottom: 2, right: 2),
        ref(3, 1, sheet: "Budget")
      )
    end

    it "translates only relative references when copying" do
      from = ref(1, 2)
      to = ref(1, 3)
      ast = described_class.parse("=A1+$A$1+$A1+A$1", origin: from)
      expect(described_class.render(described_class.translate(ast, from: from, to: to))).to eq("=B1+$A$1+$A1+B$1")
    end

    it "turns copied relative references below the grid into #REF!" do
      from = ref(2, 2)
      expect(described_class.render(described_class.translate(described_class.parse("=B1"), from: from, to: ref(1, 2)))).to eq("=#REF!")
      expect(described_class.render(described_class.translate(described_class.parse("=A2"), from: from, to: ref(2, 1)))).to eq("=#REF!")

      range = described_class.parse("=SUM(B1:C2)")
      expect(described_class.render(described_class.translate(range, from: from, to: ref(1, 2)))).to eq("=SUM(#REF!)")
      expect(described_class.render(described_class.translate(described_class.parse("=A1:B2"), from: from, to: ref(1, 1)))).to eq("=#REF!")
    end

    it "preserves absolute references when relative references underflow" do
      from = ref(2, 2)
      absolute = described_class.parse("=$A$1")
      expect(described_class.render(described_class.translate(absolute, from: from, to: ref(1, 1)))).to eq("=$A$1")
      absolute_range = described_class.parse("=$A$1:B2")
      expect(described_class.render(described_class.translate(absolute_range, from: from, to: ref(1, 1)))).to eq("=$A$1:A1")

      mixed = described_class.parse("=$A1")
      expect(described_class.render(described_class.translate(mixed, from: from, to: ref(1, 2)))).to eq("=#REF!")
    end

    it "moves unqualified references across sheets but keeps explicit sheet references" do
      from = ref(2, 2, sheet: "Source")
      to = ref(2, 3, sheet: "Destination")
      ast = described_class.parse("=A1+'Data Sheet'!A1", origin: from)
      expect(described_class.render(described_class.translate(ast, from: from, to: to), origin: to)).to eq("=B1+'Data Sheet'!B1")
    end

    it "adjusts references and ranges for row and column edits" do
      ast = described_class.parse("=SUM(A1:A10)+B5")
      inserted = described_class.adjust(ast, { type: :insert_rows, sheet: nil, at: 5, count: 1 })
      expect(described_class.render(inserted)).to eq("=SUM(A1:A11)+B6")
      deleted = described_class.adjust(ast, { type: :delete_rows, sheet: nil, at: 5, count: 1 })
      expect(described_class.render(deleted)).to eq("=SUM(A1:A9)+#REF!")

      outside = described_class.adjust(described_class.parse("=SUM(A5:A10)"),
                                       { type: :insert_rows, sheet: nil, at: 2, count: 1 })
      expect(described_class.render(outside)).to eq("=SUM(A6:A11)")
    end

    it "rejects malformed formulas rather than evaluating partial input" do
      expect { described_class.parse("=1+") }.to raise_error(Furud::ParseError)
      expect { described_class.parse("=A0") }.to raise_error(Furud::ParseError)
    end
  end

  describe Furud::Engine do
    it "uses a Source duck type without depending on a sheet implementation" do
      source = Class.new do
        def initialize(values) = @values = values
        def value_at(reference) = @values.fetch([reference.sheet, reference.row, reference.column], nil)
        def each_in(area)
          @values.each do |(sheet, row, column), value|
            reference = Furud::Reference.new(sheet: sheet, row: row, column: column)
            yield reference, value if area.include?(reference)
          end
        end
      end.new({ ["Budget", 1, 1] => 12, ["Budget", 2, 1] => 30 })
      engine = described_class.new(source)
      total = ref(1, 2, sheet: "Budget")
      engine.set(total, "=SUM(A1:A2)")

      expect(engine.value(total)).to eq(42)
    end

    it "can read ranges from a value_at-only source" do
      source = Object.new
      source.define_singleton_method(:value_at) { |cell| cell.column == 1 ? cell.row * 2 : nil }
      engine = described_class.new(source)
      total = ref(1, 2)
      engine.set(total, "=SUM(A1:A3)")

      expect(engine.value(total)).to eq(12)
    end

    it "leaves the existing cell intact when a formula fails to parse" do
      engine = described_class.new
      cell = ref(1, 1)
      engine.set(cell, "=1+1")
      expect { engine.set(cell, "=1+") }.to raise_error(Furud::ParseError)
      expect(engine.formula(cell)).to eq("=1+1")
      expect(engine.value(cell)).to eq(2)
    end

    it "returns a formula error for incorrectly sized lazy-function calls" do
      engine = described_class.new
      ["=IF()", "=IFERROR(1)", "=OFFSET(A1,1)"].each_with_index do |formula, index|
        cell = ref(index + 1, 1)
        engine.set(cell, formula)
        expect(engine.value(cell)).to eq(Furud::ErrorValue.new(code: :value))
      end
    end

    it "recalculates only changed cells and their dependents" do
      engine = described_class.new
      input = ref(1, 1)
      first = ref(1, 2)
      second = ref(1, 3)
      unrelated = ref(2, 2)
      engine.set(input, 2)
      engine.set(first, "=A1+1")
      engine.set(second, "=B1*2")
      engine.set(unrelated, "=10+1")
      engine.recalculate
      engine.set(input, 9)

      expect(engine.dirty).to contain_exactly(input, first, second)
      expect(engine.recalculate).to contain_exactly(input, first, second)
      expect(engine.value(second)).to eq(20)
      expect(engine.precedents(second)).to eq([first])
      expect(engine.dependents(input)).to eq([first])
    end

    it "matches a fresh full calculation for a deterministic 10,000-cell dependency graph" do
      engine = described_class.new
      bases = (1..26).map do |column|
        cell = ref(1, column)
        engine.set(cell, column)
        cell
      end
      formulas = []
      10_000.times do |seed|
        random = Random.new(seed)
        row = seed / 50 + 2
        step = seed % 50 + 1
        column = step + 1
        base = Furud::Formula.column_name(random.rand(1..26))
        previous = step == 1 ? "#{base}$1" : "#{Furud::Formula.column_name(column - 1)}#{row}"
        formula = "=$#{base}$1+#{previous}"
        cell = ref(row, column)
        formulas << [cell, formula]
        engine.set(cell, formula)
      end
      engine.recalculate

      bases.each_with_index { |cell, index| engine.set(cell, index + 11) }
      engine.recalculate
      actual = formulas.map { |cell, _formula| engine.value(cell) }

      fresh = described_class.new
      bases.each_with_index { |cell, index| fresh.set(cell, index + 11) }
      formulas.each { |cell, formula| fresh.set(cell, formula) }
      fresh.recalculate
      expect(actual).to eq(formulas.map { |cell, _formula| fresh.value(cell) })
    end

    it "invalidates formulas depending on ranges when a cell in the range changes" do
      engine = described_class.new
      total = ref(1, 2)
      cell = ref(2, 1)
      engine.set(total, "=SUM(A1:A3)")
      engine.set(cell, 4)
      expect(engine.value(total)).to eq(4)
      engine.set(cell, 7)
      expect(engine.value(total)).to eq(7)
      expect(engine.dependents(cell)).to eq([total])
    end

    it "detects cycles and recovers after an edit breaks the cycle" do
      engine = described_class.new
      a = ref(1, 1)
      b = ref(1, 2)
      engine.set(a, "=B1+1")
      engine.set(b, "=A1+1")
      expect(engine.value(a)).to eq(Furud::ErrorValue.new(code: :cycle))
      expect(engine.cycles).to contain_exactly([a, b])
      engine.set(b, 4)
      expect(engine.value(a)).to eq(5)
      expect(engine.cycles).to be_empty
    end

    it "converges an iterative circular calculation within its configured tolerance" do
      engine = described_class.new(nil, iterative: true, max_iterations: 200, epsilon: 0.001)
      a = ref(1, 1)
      b = ref(1, 2)
      engine.set(a, "=(B1+1)/2")
      engine.set(b, "=(A1+1)/2")
      expect(engine.value(a)).to be_within(0.001).of(1)
      expect(engine.value(b)).to be_within(0.001).of(1)
    end

    it "supports arrays, element-wise evaluation, and spill cells" do
      engine = described_class.new
      anchor = ref(1, 1)
      engine.set(anchor, "=SEQUENCE(2,2)+1")
      expect(engine.value(anchor)).to eq(2)
      expect(engine.value(ref(1, 2))).to eq(3)
      expect(engine.value(ref(2, 1))).to eq(4)
      expect(engine.value(ref(2, 2))).to eq(5)
    end

    it "sorts array columns and spills the sorted matrix" do
      engine = described_class.new
      engine.set(ref(1, 1), 4)
      engine.set(ref(1, 2), 1)
      engine.set(ref(2, 1), 2)
      engine.set(ref(2, 2), 3)
      engine.set(ref(1, 4), "=SORT(A1:B2,1,1,TRUE)")
      engine.set(ref(4, 4), "=SORT(A1:B2,1,-1,TRUE)")
      engine.set(ref(7, 4), "=SORT(A1:B2,1,1,FALSE)")

      expect(engine.value(ref(1, 4))).to eq(1)
      expect(engine.value(ref(1, 5))).to eq(4)
      expect(engine.value(ref(2, 4))).to eq(3)
      expect(engine.value(ref(2, 5))).to eq(2)

      expect(engine.value(ref(4, 4))).to eq(4)
      expect(engine.value(ref(4, 5))).to eq(1)
      expect(engine.value(ref(5, 4))).to eq(2)
      expect(engine.value(ref(5, 5))).to eq(3)

      expect(engine.value(ref(7, 4))).to eq(2)
      expect(engine.value(ref(7, 5))).to eq(3)
      expect(engine.value(ref(8, 4))).to eq(4)
      expect(engine.value(ref(8, 5))).to eq(1)
    end

    it "filters rows and columns and spills the selected cells" do
      engine = described_class.new
      engine.set(ref(1, 1), 1)
      engine.set(ref(1, 2), "one")
      engine.set(ref(2, 1), -1)
      engine.set(ref(2, 2), "skip")
      engine.set(ref(3, 1), 2)
      engine.set(ref(3, 2), "two")
      engine.set(ref(1, 4), "=FILTER(A1:B3,A1:A3>0)")

      expect(engine.value(ref(1, 4))).to eq(1)
      expect(engine.value(ref(1, 5))).to eq("one")
      expect(engine.value(ref(2, 4))).to eq(2)
      expect(engine.value(ref(2, 5))).to eq("two")

      engine.set(ref(5, 1), 1)
      engine.set(ref(5, 2), 0)
      engine.set(ref(5, 3), 2)
      engine.set(ref(6, 1), "left")
      engine.set(ref(6, 2), "middle")
      engine.set(ref(6, 3), "right")
      engine.set(ref(5, 5), "=FILTER(A5:C6,A5:C5>0)")

      expect(engine.value(ref(5, 5))).to eq(1)
      expect(engine.value(ref(5, 6))).to eq(2)
      expect(engine.value(ref(6, 5))).to eq("left")
      expect(engine.value(ref(6, 6))).to eq("right")
    end

    it "spills UNIQUE rows and columns, including exactly-once results" do
      engine = described_class.new
      [[1, "a"], [1, "a"], [2, "b"], [3, "c"]].each_with_index do |row, row_index|
        row.each_with_index { |value, column_index| engine.set(ref(row_index + 1, column_index + 1), value) }
      end
      engine.set(ref(1, 4), "=UNIQUE(A1:B4,FALSE,TRUE)")
      engine.set(ref(1, 7), "=UNIQUE(A1:B4)")

      expect(engine.value(ref(1, 4))).to eq(2)
      expect(engine.value(ref(1, 5))).to eq("b")
      expect(engine.value(ref(2, 4))).to eq(3)
      expect(engine.value(ref(2, 5))).to eq("c")
      expect(engine.value(ref(1, 7))).to eq(1)
      expect(engine.value(ref(1, 8))).to eq("a")
      expect(engine.value(ref(2, 7))).to eq(2)
      expect(engine.value(ref(3, 7))).to eq(3)

      [[1, 1, 2, 3], [4, 4, 5, 6], [7, 7, 8, 9]].each_with_index do |row, row_index|
        row.each_with_index { |value, column_index| engine.set(ref(row_index + 7, column_index + 1), value) }
      end
      engine.set(ref(7, 6), "=UNIQUE(A7:D9,TRUE,TRUE)")

      expect(engine.value(ref(7, 6))).to eq(2)
      expect(engine.value(ref(7, 7))).to eq(3)
      expect(engine.value(ref(8, 6))).to eq(5)
      expect(engine.value(ref(8, 7))).to eq(6)
      expect(engine.value(ref(9, 6))).to eq(8)
      expect(engine.value(ref(9, 7))).to eq(9)
    end

    it "uses FILTER fallbacks, reports empty results, and validates include masks" do
      engine = described_class.new
      engine.set(ref(1, 1), 1)
      engine.set(ref(2, 1), 2)
      engine.set(ref(1, 2), "=FILTER(A1:A2,A1:A2<0)")
      engine.set(ref(1, 3), "=FILTER(A1:A2,A1:A2<0,\"empty\")")
      engine.set(ref(1, 4), "=FILTER(A1:A2,A1:A2<0,{10,20})")
      engine.set(ref(1, 6), "=FILTER(A1:A2,A1:A2>0,1/0)")
      engine.set(ref(1, 7), "=ERROR.TYPE(B1)")
      engine.set(ref(1, 8), "=1/0")
      engine.set(ref(1, 9), "=FILTER(A1:A2,H1:H2,\"fallback\")")
      engine.set(ref(1, 10), "=FILTER(A1:A2,A1:A2<0,1/0)")
      engine.set(ref(4, 2), "=FILTER(A1:B2,A1:B2)")

      expect(engine.value(ref(1, 2))).to eq(Furud::ErrorValue.new(code: :calc))
      expect(engine.value(ref(1, 3))).to eq("empty")
      expect(engine.value(ref(1, 4))).to eq(10)
      expect(engine.value(ref(1, 5))).to eq(20)
      expect(engine.value(ref(1, 6))).to eq(1)
      expect(engine.value(ref(2, 6))).to eq(2)
      expect(engine.value(ref(1, 7))).to eq(14)
      expect(engine.value(ref(1, 9))).to eq(Furud::ErrorValue.new(code: :div0))
      expect(engine.value(ref(1, 10))).to eq(Furud::ErrorValue.new(code: :div0))
      expect(engine.value(ref(4, 2))).to eq(Furud::ErrorValue.new(code: :value))

      expect(Furud::Formula.render(Furud::Formula.parse("=#CALC!"))).to eq("=#CALC!")
    end

    it "returns #SPILL! rather than overwriting an occupied cell" do
      engine = described_class.new
      anchor = ref(1, 1)
      engine.set(ref(1, 2), "kept")
      engine.set(anchor, "=SEQUENCE(1,2)")
      expect(engine.value(anchor)).to eq(Furud::ErrorValue.new(code: :spill))
      expect(engine.value(ref(1, 2))).to eq("kept")
    end

    it "clears old spill cells when an array formula is replaced or cleared" do
      engine = described_class.new
      anchor = ref(1, 1)
      child = ref(1, 2)
      engine.set(anchor, "=SEQUENCE(1,2)")
      expect(engine.value(child)).to eq(2)

      engine.set(anchor, 7)
      expect(engine.recalculate).to include(child)
      expect(engine.value(child)).to be_nil

      engine.set(anchor, "=SEQUENCE(1,2)")
      engine.value(child)
      engine.clear(anchor)
      expect(engine.recalculate).to include(child)
      expect(engine.value(child)).to be_nil
    end

    it "does not spill over source values or beyond sheet boundaries" do
      source = Object.new
      source.define_singleton_method(:value_at) { |cell| cell == Furud::Reference.new(sheet: nil, row: 1, column: 2) ? 99 : nil }
      engine = described_class.new(source)
      engine.set(ref(1, 1), "=SEQUENCE(1,2)")
      expect(engine.value(ref(1, 1))).to eq(Furud::ErrorValue.new(code: :spill))

      engine = described_class.new
      engine.set(ref(1_048_576, 16_384), "=SEQUENCE(1,2)")
      expect(engine.value(ref(1_048_576, 16_384))).to eq(Furud::ErrorValue.new(code: :spill))
    end

    it "translates formulas with row insertion and deletion" do
      engine = described_class.new
      formula = ref(5, 2)
      engine.set(ref(5, 1), 8)
      engine.set(formula, "=A5")
      engine.insert_rows(nil, 2, 1)
      moved = ref(6, 2)
      expect(engine.formula(moved)).to eq("=A6")
      expect(engine.value(moved)).to eq(8)
      engine.set(ref(1, 2), "=A6")
      engine.delete_rows(nil, 6, 1)
      expect(engine.formula(ref(1, 2))).to eq("=#REF!")
      expect(engine.value(ref(1, 2))).to eq(Furud::ErrorValue.new(code: :ref))
    end

    it "supports defined range names, INDIRECT, and OFFSET" do
      engine = described_class.new
      engine.set(ref(1, 1), 3)
      engine.set(ref(2, 1), 4)
      engine.define_name("inputs", Furud::Area.new(sheet: nil, top: 1, left: 1, bottom: 2, right: 1))
      engine.set(ref(1, 2), "=SUM(inputs)")
      engine.set(ref(1, 3), "=INDIRECT(\"A1\")+OFFSET(A1,1,0)")
      expect(engine.value(ref(1, 2))).to eq(7)
      expect(engine.value(ref(1, 3))).to eq(7)
    end

    it "tracks dependencies through named ranges, including redefinitions" do
      engine = described_class.new
      engine.set(ref(1, 1), 3)
      engine.set(ref(1, 2), 4)
      total = ref(1, 3)
      engine.set(total, "=SUM(inputs)")
      engine.define_name("inputs", Furud::Area.new(sheet: nil, top: 1, left: 1, bottom: 1, right: 1))
      expect(engine.value(total)).to eq(3)
      expect(engine.dependents(ref(1, 1))).to eq([total])
      engine.set(ref(1, 1), 9)
      expect(engine.value(total)).to eq(9)

      engine.define_name("inputs", Furud::Area.new(sheet: nil, top: 1, left: 2, bottom: 1, right: 2))
      expect(engine.value(total)).to eq(4)
      engine.set(ref(1, 2), 8)
      expect(engine.value(total)).to eq(8)
    end
  end

  describe Furud::Functions do
    it "registers the documented standard function set" do
      functions = described_class.standard
      expect(functions.names.length).to eq(192)
      expect(functions.call("SUM", 1, 2, 3)).to eq(6)
      expect(functions.call("AVERAGE", [2, 4, 6])).to eq(4)
      expect(functions.call("PMT", 0.1, 12, 1000)).to be_within(0.001).of(-146.763)
      expect(functions.call("NOT", true)).to be(false)
      expect(functions.call("LEFT", "Canopus", 3)).to eq("Can")
      expect(functions.call("DATE", 2024, 2, 30)).to eq(Date.new(2024, 3, 1))
      expect(functions.call("FILTER", [[1, 2], [3, 4]], [true, false]).rows).to eq([[1], [3]])
    end

    it "matches the UNIQUE row, column, and exactly-once case table" do
      functions = described_class.standard
      rows = Furud::ArrayValue.new(rows: [[1, "a"], [1, "a"], [2, "b"], [3, "c"]])
      columns = Furud::ArrayValue.new(rows: [[1, 1, 2, 3], [4, 4, 5, 6], [7, 7, 8, 9]])
      error = Furud::ErrorValue.new(code: :ref)
      cases = [
        ["unique rows", [rows], [[1, "a"], [2, "b"], [3, "c"]]],
        ["flat list", [[1, 2, 1]], [[1], [2]]],
        ["one row", [Furud::ArrayValue.new(rows: [[1, 1, 2]])], [[1, 1, 2]]],
        ["singleton rows", [rows, false, true], [[2, "b"], [3, "c"]]],
        ["unique columns", [columns, true], [[1, 2, 3], [4, 5, 6], [7, 8, 9]]],
        ["singleton columns", [columns, true, true], [[2, 3], [5, 6], [8, 9]]],
        ["numeric logical flags", [columns, 1, 1], [[2, 3], [5, 6], [8, 9]]],
        ["empty singleton result", [Furud::ArrayValue.new(rows: [[1], [1]]), false, true], Furud::ErrorValue.new(code: :calc)],
        ["invalid logical flag", [rows, "TRUE"], Furud::ErrorValue.new(code: :value)],
        ["out-of-range logical flag", [rows, 2], Furud::ErrorValue.new(code: :value)],
        ["ragged array", [[[1], [2, 3]]], Furud::ErrorValue.new(code: :value)],
        ["input error propagation", [Furud::ArrayValue.new(rows: [[error]])], error],
        ["missing array argument", [], Furud::ErrorValue.new(code: :value)],
        ["too many arguments", [rows, false, true, 0], Furud::ErrorValue.new(code: :value)]
      ]

      cases.each do |label, arguments, expected|
        result = functions.call("UNIQUE", *arguments)
        expect(result.is_a?(Furud::ArrayValue) ? result.rows : result).to eq(expected), label
      end
    end

    it "checks selected standard function cases with exact error values" do
      functions = described_class.standard
      reference_error = Furud::ErrorValue.new(code: :ref)
      division_error = Furud::ErrorValue.new(code: :div0)
      calc_error = Furud::ErrorValue.new(code: :calc)
      array = Furud::ArrayValue.new(rows: [[1], [2]])
      mismatch = Furud::ArrayValue.new(rows: [[true, false], [false, true]])
      include_error = Furud::ArrayValue.new(rows: [[true], [reference_error]])
      match_values = Furud::ArrayValue.new(rows: [[10], [20], [30]])
      cases = [
        ["ABS", [-5], 5],
        ["SUM", [1, 2, 3], 6],
        ["SUM", [1, reference_error], reference_error],
        ["AVERAGE", [1, 2, 3], 2.0],
        ["AVERAGE", [array, reference_error], reference_error],
        ["VAR.S", [4], division_error],
        ["IFERROR", [reference_error, "fallback"], "fallback"],
        ["LEFT", ["Canopus", 3], "Can"],
        ["DATE", [2024, 2, 29], Date.new(2024, 2, 29)],
        ["MATCH", [20, match_values, 0], 2],
        ["PMT", [0, 10, 1000], -100.0],
        ["FILTER", [array, mismatch], Furud::ErrorValue.new(code: :value)],
        ["FILTER", [array, include_error], reference_error],
        ["ADDRESS", [3, 2, 2], "B$3"],
        ["ADDRESS", [3, 2, 3], "$B3"],
        ["ADDRESS", [3, 2, 4], "B3"],
        ["ADDRESS", [2, 3, 2, false], "R2C[3]"],
        ["ADDRESS", [2, 3, 1, false, "Sheet 1"], "'Sheet 1'!R2C3"],
        ["ADDRESS", [3, 2, 5], Furud::ErrorValue.new(code: :value)],
        ["EVEN", [-3], -4],
        ["MROUND", [-5, -2], -6],
        ["MROUND", [5, -2], Furud::ErrorValue.new(code: :num)],
        ["EOMONTH", [Date.new(2024, 1, 31), 0], Date.new(2024, 1, 31)],
        ["DDB", [100, 10, 5, 2], 24.0],
        ["DDB", [100, 10, 0, 1], Furud::ErrorValue.new(code: :num)],
        ["ERROR.TYPE", [calc_error], 14]
      ]

      cases.each do |name, arguments, expected|
        expect(functions.call(name, *arguments)).to eq(expected), "#{name}(#{arguments.inspect})"
      end
    end

    it "checks explicit expected values for at least 120 standard functions" do
      functions = described_class.standard
      vector = Furud::ArrayValue.new(rows: [[1], [2], [3]])
      matrix = Furud::ArrayValue.new(rows: [[1, 2], [3, 4]])
      table = Furud::ArrayValue.new(rows: [[1, "a"], [2, "b"], [3, "c"]])
      row_table = Furud::ArrayValue.new(rows: [[1, 2, 3], ["a", "b", "c"]])
      reference = Furud::Reference.new(row: 5, column: 3)
      timestamp = Time.new(2024, 1, 1, 12, 34, 56)
      cases = [
        # Arithmetic and math.
        ["ABS", [-2], 2], ["ACOS", [1], 0.0], ["ACOSH", [1], 0.0], ["ASIN", [0], 0.0],
        ["ASINH", [0], 0.0], ["ATAN", [0], 0.0], ["ATAN2", [1, 0], 0.0], ["ATANH", [0], 0.0],
        ["COS", [0], 1.0], ["COSH", [0], 1.0], ["DEGREES", [Math::PI], 180.0], ["EXP", [0], 1.0],
        ["INT", [-1.2], -2], ["LN", [1], 0.0], ["LOG10", [100], 2.0], ["LOG", [100], 2.0],
        ["RADIANS", [180], Math::PI], ["SIGN", [-3], -1], ["SIN", [0], 0.0], ["SINH", [0], 0.0],
        ["SQRT", [9], 3.0], ["TAN", [0], 0.0], ["TANH", [0], 0.0], ["EVEN", [3], 4],
        ["ODD", [2], 3], ["FACT", [5], 120], ["FACTDOUBLE", [5], 15], ["SQRTPI", [0], 0.0],
        ["SEC", [0], 1.0], ["SECH", [0], 1.0], ["TRUNC", [12.9], 12], ["PI", [], Math::PI],
        ["POWER", [2, 3], 8], ["MOD", [10, 3], 1], ["QUOTIENT", [10, 3], 3], ["ROUND", [1.236, 2], 1.24],
        ["ROUNDDOWN", [1.239, 2], 1.23], ["ROUNDUP", [1.231, 2], 1.24], ["FLOOR", [5, 2], 4],
        ["CEILING", [5, 2], 6], ["FLOOR.MATH", [5, 2], 4], ["CEILING.MATH", [5, 2], 6],
        ["ISO.CEILING", [5, 2], 6], ["MROUND", [5, 2], 6], ["COMBIN", [5, 2], 10],
        ["COMBINA", [3, 2], 6], ["MULTINOMIAL", [2, 3], 10], ["GCD", [12, 18], 6], ["LCM", [4, 6], 12],
        ["PRODUCT", [2, 3, 4], 24], ["SUM", [1, 2, 3], 6], ["SUMSQ", [2, 3], 13],
        ["SUBTOTAL", [9, 1, 2, 3], 6],
        # Statistics.
        ["AVERAGE", [1, 2, 3], 2.0], ["AVERAGEA", [[1, true, false, "text"]], 0.5],
        ["AVERAGEIF", [[1, 2, 3], ">1"], 2.5], ["AVERAGEIFS", [[1, 2, 3], [1, 2, 3], ">1"], 2.5],
        ["COUNT", [[1, "text", true, nil]], 1], ["COUNTA", [[1, "", true, nil]], 2],
        ["COUNTBLANK", [[nil, "", 1]], 2], ["COUNTIF", [[1, 2, 3], ">1"], 2],
        ["COUNTIFS", [[1, 2, 3], ">=2", [1, 2, 3], "<=2"], 1], ["MAX", [[1, 4, 2]], 4],
        ["MIN", [[1, 4, 2]], 1], ["MAXA", [[1, true, false, "text"]], 1],
        ["MINA", [[1, true, false, "text"]], 0], ["MEDIAN", [[1, 3, 2]], 2],
        ["MODE.SNGL", [[1, 2, 2, 3]], 2], ["LARGE", [[1, 2, 3, 4], 2], 3],
        ["SMALL", [[1, 2, 3, 4], 2], 2], ["STDEV.S", [1, 2, 3], 1.0],
        ["STDEV.P", [1, 2, 3], Math.sqrt(2.0 / 3)], ["VAR.S", [1, 2, 3], 1.0],
        ["VAR.P", [1, 2, 3], 2.0 / 3],
        # Logic and text.
        ["TRUE", [], true], ["FALSE", [], false], ["AND", [true, 1], true], ["OR", [false, true], true],
        ["XOR", [true, false], true], ["NOT", [true], false], ["IF", [true, "yes", "no"], "yes"],
        ["IFNA", [Furud::ErrorValue.new(code: :na), "fallback"], "fallback"],
        ["IFS", [false, "no", true, "yes"], "yes"], ["SWITCH", ["b", "a", 1, "b", 2, 0], 2],
        ["CONCAT", ["a", ["b", "c"]], "abc"], ["CONCATENATE", ["a", "b"], "ab"],
        ["TEXTJOIN", [":", true, ["a", "", "b"]], "a:b"], ["EXACT", ["same", "same"], true],
        ["LEFT", ["Canopus", 3], "Can"], ["RIGHT", ["Canopus", 3], "pus"],
        ["MID", ["Canopus", 2, 3], "ano"], ["LEN", ["abc"], 3], ["LOWER", ["ABC"], "abc"],
        ["UPPER", ["abc"], "ABC"], ["PROPER", ["cANIS mAJOR"], "Canis Major"],
        ["TRIM", ["  a   b  "], "a b"], ["CLEAN", ["\u0001abc"], "abc"], ["REPT", ["ab", 3], "ababab"],
        ["FIND", ["a", "Canopus"], 2], ["SEARCH", ["A", "Canopus"], 2],
        ["REPLACE", ["abcdef", 2, 3, "X"], "aXef"], ["SUBSTITUTE", ["abab", "a", "x", 2], "abxb"],
        ["TEXT", [12, "0.00"], "12.00"], ["VALUE", ["1,234.5"], 1234.5], ["CHAR", [65], "A"],
        ["CODE", ["A"], 65], ["UNICHAR", [9731], "☃"], ["UNICODE", ["☃"], 9731],
        # Dates and time.
        ["DATE", [2024, 2, 29], Date.new(2024, 2, 29)], ["DATEVALUE", ["2024-01-02"], 45_293],
        ["DAY", [Date.new(2024, 3, 5)], 5], ["MONTH", [Date.new(2024, 3, 5)], 3],
        ["YEAR", [Date.new(2024, 3, 5)], 2024], ["DAYS", [Date.new(2024, 1, 3), Date.new(2024, 1, 1)], 2],
        ["DAYS360", [Date.new(2024, 1, 1), Date.new(2024, 12, 31)], 360],
        ["EDATE", [Date.new(2024, 1, 31), 1], Date.new(2024, 2, 29)],
        ["EOMONTH", [Date.new(2024, 1, 31), 1], Date.new(2024, 2, 29)],
        ["HOUR", [timestamp], 12], ["MINUTE", [timestamp], 34], ["SECOND", [timestamp], 56],
        ["TIME", [6, 0, 0], 0.25], ["TIMEVALUE", ["6:00 AM"], 0.25],
        ["WEEKDAY", [Date.new(2024, 1, 1)], 2], ["WEEKNUM", [Date.new(2024, 1, 7)], 2],
        ["ISOWEEKNUM", [Date.new(2024, 1, 1)], 1],
        ["NETWORKDAYS", [Date.new(2024, 1, 1), Date.new(2024, 1, 5)], 5],
        ["WORKDAY", [Date.new(2024, 1, 1), 5], Date.new(2024, 1, 8)],
        ["YEARFRAC", [Date.new(2024, 1, 1), Date.new(2024, 1, 2), 1], 1.0 / 366],
        # Lookup, information, finance, and arrays.
        ["CHOOSE", [2, "first", "second"], "second"], ["INDEX", [matrix, 2, 1], 3],
        ["VLOOKUP", [2, table, 2, false], "b"], ["HLOOKUP", [2, row_table, 2, false], "b"],
        ["LOOKUP", [2, vector], 2], ["ADDRESS", [3, 2], "$B$3"], ["ROW", [reference], 5],
        ["COLUMN", [reference], 3], ["ROWS", [matrix], 2], ["COLUMNS", [matrix], 2],
        ["AREAS", [matrix], 1], ["ISBLANK", [nil], true], ["ISERROR", [Furud::ErrorValue.new(code: :ref)], true],
        ["ISNUMBER", [42], true], ["ISREF", [reference], true], ["TYPE", ["text"], 2], ["N", [true], 1],
        ["FORMULATEXT", ["=SUM(A1:A2)"], "=SUM(A1:A2)"], ["HYPERLINK", ["https://example.test", "Open"], "Open"],
        ["FV", [0, 10, 100], -1000.0], ["PV", [0, 10, 100], -1000.0], ["NPER", [0, -100, 1000], 10.0],
        ["NPV", [0, 1, 2, 3], 6.0], ["SLN", [100, 10, 3], 30.0], ["SYD", [100, 10, 3, 1], 45.0],
        ["DDB", [100, 10, 5, 1], 40.0], ["EFFECT", [0.0625, 1], 0.0625], ["NOMINAL", [0.0625, 1], 0.0625],
        ["TRANSPOSE", [matrix], [[1, 3], [2, 4]]], ["SEQUENCE", [2, 3], [[1, 2, 3], [4, 5, 6]]],
        ["SORT", [Furud::ArrayValue.new(rows: [[3], [1], [2]])], [[1], [2], [3]]]
      ]

      names = cases.map(&:first)
      expect(names.uniq.length).to eq(names.length)
      expect(names.uniq.length).to be >= 120
      cases.each do |name, arguments, expected|
        result = functions.call(name, *arguments)
        result = result.rows if result.is_a?(Furud::ArrayValue)
        expect(result).to eq(expected), "#{name}(#{arguments.inspect})"
      end
    end

    it "checks ordinary results for previously uncovered standard functions" do
      functions = described_class.standard
      close_cases = [
        ["COT", [Math.atan(0.5)], 2.0], ["COTH", [Math.atanh(0.5)], 2.0],
        ["CSC", [Math.asin(0.5)], 2.0], ["CSCH", [Math.asinh(2.0)], 0.5],
        ["DB", [1_000_000, 100_000, 6, 1, 7], 186_083.33],
        ["DB", [1_000_000, 100_000, 6, 2, 7], 259_639.42],
        ["DB", [1_000_000, 100_000, 6, 7, 7], 15_845.10],
        ["IRR", [[-70_000, 12_000, 15_000, 18_000, 21_000, 26_000]], 0.08663094803653158],
        ["MIRR", [[-120_000, 39_000, 59_000, 55_000, 20_000], 0.1, 0.12], 0.1507130731097608],
        ["RATE", [10, 0, -1_000, 2_000], 0.0717734625363203]
      ]
      close_cases.each do |name, arguments, expected|
        expect(functions.call(name, *arguments)).to be_within(0.005).of(expected), "#{name}(#{arguments.inspect})"
      end

      ref_error = Furud::ErrorValue.new(code: :ref)
      na_error = Furud::ErrorValue.new(code: :na)
      exact_cases = [
        ["ISERR", [ref_error], true], ["ISERR", [na_error], false],
        ["ISEVEN", [4], true], ["ISFORMULA", ["=A1"], false],
        ["ISLOGICAL", [false], true], ["ISNA", [na_error], true],
        ["ISNONTEXT", [42], true], ["ISODD", [3], true], ["ISTEXT", ["text"], true],
        ["NA", [], na_error],
        ["SUMIF", [["a", "b", "a"], "a", [10, 20, 30]], 40],
        ["SUMIFS", [[10, 20, 30, 40], ["a", "b", "a", "a"], "a", [1, 2, 3, 1], ">1"], 30],
        ["SUMIFS", [Furud::ArrayValue.new(rows: [[1, 2], [3, 4]]), ["a", "b", "c", "d"], "a"], Furud::ErrorValue.new(code: :value)],
        ["XLOOKUP", [20, Furud::ArrayValue.new(rows: [[10], [20], [30]]), Furud::ArrayValue.new(rows: [["a"], ["b"], ["c"]])], "b"],
        ["XLOOKUP", [20, [10, 20, 30], ["a", "b", "c"], "missing"], "b"]
      ]
      exact_cases.each do |name, arguments, expected|
        expect(functions.call(name, *arguments)).to eq(expected), "#{name}(#{arguments.inspect})"
      end
      expect(functions.call("IRR", [-100, 110], 0.05)).to be_within(1e-9).of(0.1)
      expect(functions.call("DB", 100, 10, 5, 0)).to eq(Furud::ErrorValue.new(code: :num))
    end

    it "limits XLOOKUP to exact forward matching and validates result dimensions" do
      functions = described_class.standard
      lookups = Furud::ArrayValue.new(rows: [[10], [20], [30]])
      results = Furud::ArrayValue.new(rows: [["a", "A"], ["b", "B"], ["c", "C"]])
      expect(functions.call("XLOOKUP", 20, lookups, results)).to eq(Furud::ArrayValue.new(rows: [["b", "B"]]))
      expect(functions.call("XLOOKUP", 20, [10, 20, 30], ["a", "b", "c"], "missing", -1)).to eq(Furud::ErrorValue.new(code: :value))
      expect(functions.call("XLOOKUP", 20, [10, 20, 30], ["a", "b", "c"], "missing", 0.5)).to eq(Furud::ErrorValue.new(code: :value))
      expect(functions.call("XLOOKUP", 20, [10, 20, 30], ["a", "b"], "missing")).to eq(Furud::ErrorValue.new(code: :value))
      expect(functions.call("XLOOKUP", 40, [10, 20, 30], ["a", "b", "c"])).to eq(Furud::ErrorValue.new(code: :na))
      horizontal = Furud::ArrayValue.new(rows: [[10, 20, 30]])
      returns = Furud::ArrayValue.new(rows: [["a", "b", "c"], ["d", "e", "f"]])
      expect(functions.call("XLOOKUP", 20, horizontal, returns)).to eq(Furud::ArrayValue.new(rows: [["b"], ["e"]]))
    end

    it "checks volatile function result ranges and volatility metadata" do
      functions = described_class.standard
      %w[NOW TODAY RAND RANDBETWEEN OFFSET].each do |name|
        expect(functions[name].volatile).to be(true), name
      end

      before = Time.now
      now = functions.call("NOW")
      after = Time.now
      expect(now).to be_between(before, after).inclusive
      expect(functions.call("TODAY")).to eq(Date.today)
      expect(functions.call("RAND")).to be_between(0.0, 1.0).exclusive
      expect(functions.call("RANDBETWEEN", 7, 7)).to eq(7)
      100.times do
        value = functions.call("RANDBETWEEN", 2, 5)
        expect(value).to be_a(Integer)
        expect(value).to be_between(2, 5).inclusive
      end
    end

    it "keeps reference-dependent functions in Engine and reports unsupported CELL metadata" do
      functions = described_class.standard
      expect(functions.call("CELL", "filename")).to eq(Furud::ErrorValue.new(code: :value))
      expect(functions.call("ISFORMULA", "=A1")).to be(false)

      engine = Furud::Engine.new
      engine.set(ref(1, 1), 3)
      engine.set(ref(2, 1), 4)
      engine.set(ref(1, 2), "=ISFORMULA(A1)")
      engine.set(ref(1, 3), "=ISFORMULA(B1)")
      engine.set(ref(2, 2), "=INDIRECT(\"A1\")")
      engine.set(ref(2, 3), "=OFFSET(A1,1,0)")
      expect(engine.value(ref(1, 2))).to be(false)
      expect(engine.value(ref(1, 3))).to be(true)
      expect(engine.value(ref(2, 2))).to eq(3)
      expect(engine.value(ref(2, 3))).to eq(4)
    end

    it "validates custom function arity and propagates standard errors" do
      functions = Furud::Functions::Registry.new
      functions.register("TWICE", arity: 1) { |number| number * 2 }
      expect(functions.call("TWICE", 3)).to eq(6)
      expect(functions.call("TWICE")).to eq(Furud::ErrorValue.new(code: :value))
      expect(functions.call("UNKNOWN")).to eq(Furud::ErrorValue.new(code: :name))
    end

    it "preserves statistical errors returned by variance functions" do
      functions = described_class.standard
      expect(functions.call("VAR.S", 4)).to eq(Furud::ErrorValue.new(code: :div0))
      expect(functions.call("VAR.P", [])).to eq(Furud::ErrorValue.new(code: :num))
      expect(functions.call("VAR.S", 1, 2, 3)).to eq(1.0)
      expect(functions.call("VAR.P", 1, 2, 3)).to be_within(1e-12).of(2.0 / 3)

      engine = Furud::Engine.new
      cell = Furud::Reference.new(row: 1, column: 1)
      engine.set(cell, "=VAR.S(4)")
      expect(engine.value(cell)).to eq(Furud::ErrorValue.new(code: :div0))
    end
  end

  describe Furud::Format do
    it "formats numbers, conditions, locales, dates, and text" do
      expect(described_class.apply(1234.5, described_class.parse("#,##0.00"))).to eq(["1,234.50", { section: 0 }])
      negative = described_class.apply(-12, described_class.parse("0.0;[Red](0.0)"))
      expect(negative).to eq(["(12.0)", { section: 1, color: :red }])
      expect(described_class.apply(0.25, described_class.parse("0%")).first).to eq("25%")
      expect(described_class.apply(1234.5, described_class.parse("#,##0.0", locale: :de)).first).to eq("1.234,5")
      expect(described_class.apply(Date.new(2024, 2, 3), described_class.parse("yyyy/mm/dd")).first).to eq("2024/02/03")
      expect(described_class.apply("hello", described_class.parse("@")).first).to eq("hello")
      expect(described_class.infer("12,5", locale: :de)).to eq([12.5, "0.00"])
    end
  end
end
