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
    it "provides more than 120 registered standard functions" do
      functions = described_class.standard
      expect(functions.names.length).to be >= 120
      expect(functions.call("SUM", 1, 2, 3)).to eq(6)
      expect(functions.call("AVERAGE", [2, 4, 6])).to eq(4)
      expect(functions.call("PMT", 0.1, 12, 1000)).to be_within(0.001).of(-146.763)
      expect(functions.call("NOT", true)).to be(false)
      expect(functions.call("LEFT", "Canopus", 3)).to eq("Can")
      expect(functions.call("DATE", 2024, 2, 30)).to eq(Date.new(2024, 3, 1))
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
