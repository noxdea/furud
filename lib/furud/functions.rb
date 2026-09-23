# frozen_string_literal: true

require "date"
require "time"
require "set"

module Furud
  module Functions
    Entry = Struct.new(:name, :arity, :volatile, :implementation, keyword_init: true) do
      ERROR_HANDLERS = %w[IF IFERROR IFNA FILTER COUNTIF COUNTIFS SUMIF SUMIFS AVERAGEIF AVERAGEIFS].freeze

      def call(*args)
        return ErrorValue.new(code: :value) unless arity_match?(args.length)
        unless handles_errors?
          error = args.lazy.map { |value| first_error(value) }.find(&:itself)
          return error if error
        end

        implementation.call(*args)
      rescue ZeroDivisionError
        ErrorValue.new(code: :div0)
      rescue Math::DomainError, RangeError
        ErrorValue.new(code: :num)
      rescue ArgumentError, TypeError, FloatDomainError
        ErrorValue.new(code: :value)
      end

      def accepts?(count) = arity_match?(count)

      private

      def arity_match?(count)
        case arity
        when Integer then count == arity
        when Range then arity.cover?(count)
        when Array then arity.include?(count)
        else true
        end
      end

      def handles_errors?
        ERROR_HANDLERS.include?(name) || name.start_with?("IS") || name == "ERROR.TYPE"
      end

      def first_error(value)
        case value
        when ErrorValue then value
        when ArrayValue then value.rows.flatten.find { |cell| cell.is_a?(ErrorValue) }
        when Array then value.flatten.find { |cell| cell.is_a?(ErrorValue) }
        end
      end
    end

    class Registry
      include Enumerable

      def initialize
        @entries = {}
      end

      def initialize_copy(other)
        super
        @entries = other.instance_variable_get(:@entries).dup
      end

      def register(name, arity:, volatile: false, &implementation)
        raise ArgumentError, "implementation block is required" unless implementation

        name = name.to_s.upcase
        raise ArgumentError, "invalid function name: #{name}" unless name.match?(/\A[A-Z][A-Z0-9_.]*\z/)
        raise ArgumentError, "function already registered: #{name}" if @entries.key?(name)

        @entries[name] = Entry.new(name: name, arity: arity, volatile: !!volatile,
                                   implementation: implementation)
        self
      end

      def [](name) = @entries[name.to_s.upcase]
      def names = @entries.keys.sort.freeze
      def each(&block) = @entries.values.each(&block)
      def size = @entries.size

      def call(name, *args)
        entry = self[name]
        return ErrorValue.new(code: :name) unless entry

        entry.call(*args)
      end
    end

    module_function

    def standard
      (@standard ||= build_standard).dup
    end

    def build_standard
      registry = Registry.new
      register_math(registry)
      register_statistics(registry)
      register_logic_and_text(registry)
      register_dates(registry)
      register_lookup_and_info(registry)
      register_finance(registry)
      registry
    end

    def register_math(registry)
      unary = {
        "ABS" => ->(x) { x.abs }, "ACOS" => Math.method(:acos), "ACOSH" => Math.method(:acosh),
        "ASIN" => Math.method(:asin), "ASINH" => Math.method(:asinh), "ATAN" => Math.method(:atan),
        "ATANH" => Math.method(:atanh), "COS" => Math.method(:cos), "COSH" => Math.method(:cosh),
        "DEGREES" => ->(x) { x * 180 / Math::PI }, "EXP" => Math.method(:exp), "INT" => ->(x) { x.floor },
        "LN" => Math.method(:log), "LOG10" => Math.method(:log10), "RADIANS" => ->(x) { x * Math::PI / 180 },
        "SIGN" => ->(x) { x <=> 0 }, "SIN" => Math.method(:sin), "SINH" => Math.method(:sinh),
        "SQRT" => Math.method(:sqrt), "TAN" => Math.method(:tan), "TANH" => Math.method(:tanh),
        "EVEN" => ->(x) { round_multiple(x.abs.ceil, 2) * (x.negative? ? -1 : 1) },
        "ODD" => ->(x) { n = x.abs.ceil; n.even? ? (n + 1) * (x.negative? ? -1 : 1) : n * (x.negative? ? -1 : 1) },
        "FACT" => ->(x) { factorial(x) }, "FACTDOUBLE" => ->(x) { double_factorial(x) },
        "SQRTPI" => ->(x) { Math.sqrt(Math::PI * x) }, "SEC" => ->(x) { 1 / Math.cos(x) },
        "SECH" => ->(x) { 1 / Math.cosh(x) }, "CSC" => ->(x) { 1 / Math.sin(x) },
        "CSCH" => ->(x) { 1 / Math.sinh(x) }, "COT" => ->(x) { 1 / Math.tan(x) },
        "COTH" => ->(x) { 1 / Math.tanh(x) }
      }
      unary.each do |name, fn|
        register(registry, name, 1) { |x| fn.call(number!(x)) }
      end
      register(registry, "TRUNC", 1..2) { |x, digits = 0| truncate_decimal(number!(x), integer!(digits)) }
      register(registry, "PI", 0) { Math::PI }
      register(registry, "RAND", 0, volatile: true) { rand }
      register(registry, "RANDBETWEEN", 2, volatile: true) { |a, b| rand(integer!(a)..integer!(b)) }
      register(registry, "POWER", 2) { |a, b| number!(a)**number!(b) }
      register(registry, "MOD", 2) { |a, b| number!(a) % number!(b) }
      register(registry, "QUOTIENT", 2) { |a, b| (number!(a) / number!(b)).truncate }
      register(registry, "ATAN2", 2) { |x, y| Math.atan2(number!(y), number!(x)) }
      register(registry, "LOG", 1..2) { |x, base = 10| Math.log(number!(x), number!(base)) }
      register(registry, "ROUND", 1..2) { |x, n = 0| number!(x).round(integer!(n)) }
      register(registry, "ROUNDDOWN", 1..2) { |x, n = 0| truncate_decimal(number!(x), integer!(n)) }
      register(registry, "ROUNDUP", 1..2) { |x, n = 0| round_up(number!(x), integer!(n)) }
      %w[FLOOR CEILING FLOOR.MATH CEILING.MATH ISO.CEILING].each do |name|
        register(registry, name, 1..3) do |number, significance = 1, mode = 0|
          floor_ceiling(number!(number), number!(significance), name.start_with?("CEILING", "ISO"), number!(mode))
        end
      end
      register(registry, "MROUND", 2) do |x, multiple|
        number = number!(x); step = number!(multiple)
        if (number.negative? && step.positive?) || (number.positive? && step.negative?)
          ErrorValue.new(code: :num)
        else
          round_multiple(number, step)
        end
      end
      register(registry, "COMBIN", 2) { |n, k| choose(integer!(n), integer!(k)) }
      register(registry, "COMBINA", 2) { |n, k| choose(integer!(n) + integer!(k) - 1, integer!(k)) }
      register(registry, "MULTINOMIAL", 1..100) { |*xs| factorial(xs.sum { |x| integer!(x) }) / xs.reduce(1) { |p, x| p * factorial(integer!(x)) } }
      register(registry, "GCD", 1..255) { |*xs| xs.map { |x| integer!(x).abs }.reduce(0, :gcd) }
      register(registry, "LCM", 1..255) { |*xs| xs.map { |x| integer!(x).abs }.reduce(1) { |a, b| a.zero? || b.zero? ? 0 : a.lcm(b) } }
      register(registry, "PRODUCT", 1..255) { |*xs| numeric_values(xs).reduce(1, :*) }
      register(registry, "SUM", 0..255) { |*xs| numeric_values(xs).sum }
      register(registry, "SUMSQ", 1..255) { |*xs| numeric_values(xs).sum { |x| x * x } }
      register(registry, "SUBTOTAL", 2..255) do |function, *xs|
        values = numeric_values(xs)
        case integer!(function)
        when 1, 101 then average(values)
        when 2, 102 then xs.flatten.count { |x| numeric?(x) }
        when 4, 104 then values.max || 0
        when 5, 105 then values.min || 0
        when 9, 109 then values.sum
        else ErrorValue.new(code: :value)
        end
      end
    end

    def register_statistics(registry)
      register(registry, "AVERAGE", 1..255) { |*xs| average(numeric_values(xs)) }
      register(registry, "AVERAGEA", 1..255) { |*xs| vals = flatten(xs).map { |x| x.nil? ? 0 : (x == true ? 1 : x == false || x.is_a?(String) ? 0 : number!(x)) }; average(vals) }
      register(registry, "COUNT", 1..255) { |*xs| flatten(xs).count { |x| numeric?(x) } }
      register(registry, "COUNTA", 1..255) { |*xs| flatten(xs).count { |x| !x.nil? && x != "" } }
      register(registry, "COUNTBLANK", 1) { |x| flatten([x]).count { |v| v.nil? || v == "" } }
      register(registry, "MAX", 1..255) { |*xs| numeric_values(xs).max || 0 }
      register(registry, "MIN", 1..255) { |*xs| numeric_values(xs).min || 0 }
      register(registry, "MAXA", 1..255) { |*xs| comparable_values(xs).max || 0 }
      register(registry, "MINA", 1..255) { |*xs| comparable_values(xs).min || 0 }
      register(registry, "MEDIAN", 1..255) { |*xs| median(numeric_values(xs)) }
      register(registry, "MODE.SNGL", 1..255) do |*xs|
        values = numeric_values(xs)
        frequencies = values.tally
        max = frequencies.values.max
        max && max > 1 ? frequencies.select { |_, count| count == max }.keys.min : ErrorValue.new(code: :na)
      end
      register(registry, "LARGE", 2) { |array, k| numeric_values([array]).sort.reverse.fetch(integer!(k) - 1) { ErrorValue.new(code: :num) } }
      register(registry, "SMALL", 2) { |array, k| numeric_values([array]).sort.fetch(integer!(k) - 1) { ErrorValue.new(code: :num) } }
      register(registry, "STDEV.S", 1..255) { |*xs| deviation(numeric_values(xs), sample: true) }
      register(registry, "STDEV.P", 1..255) { |*xs| deviation(numeric_values(xs), sample: false) }
      register(registry, "VAR.S", 1..255) do |*xs|
        result = deviation(numeric_values(xs), sample: true)
        result.is_a?(ErrorValue) ? result : result**2
      end
      register(registry, "VAR.P", 1..255) do |*xs|
        result = deviation(numeric_values(xs), sample: false)
        result.is_a?(ErrorValue) ? result : result**2
      end
      register(registry, "COUNTIF", 2) { |range, criteria| flatten([range]).count { |x| criterion_match?(x, criteria) } }
      register(registry, "COUNTIFS", 2..255) do |*xs|
        ranges = xs.each_slice(2).map { |range, criteria| [flatten([range]), criteria] }
        if xs.length.odd?
          ErrorValue.new(code: :value)
        else
          size = ranges.first.first.length
          ranges.all? { |values, _| values.length == size } ? (0...size).count { |i| ranges.all? { |values, criteria| criterion_match?(values[i], criteria) } } : ErrorValue.new(code: :value)
        end
      end
      register(registry, "SUMIF", 2..3) do |range, criteria, sum_range = range|
        values = flatten([range]); sums = flatten([sum_range])
        values.each_index.sum { |i| criterion_match?(values[i], criteria) ? number_or_zero(sums[i]) : 0 }
      end
      register(registry, "SUMIFS", 3..255) do |sum_range, *xs|
        sums = flatten([sum_range]); ranges = xs.each_slice(2).map { |r, c| [flatten([r]), c] }
        if xs.length.odd?
          ErrorValue.new(code: :value)
        else
          (0...sums.length).sum { |i| ranges.all? { |values, criteria| values[i] && criterion_match?(values[i], criteria) } ? number_or_zero(sums[i]) : 0 }
        end
      end
      register(registry, "AVERAGEIF", 2..3) do |range, criteria, average_range = range|
        pairs = flatten([range]).zip(flatten([average_range])).select { |value, _| criterion_match?(value, criteria) }
        average(pairs.map { |_, value| number_or_zero(value) })
      end
      register(registry, "AVERAGEIFS", 3..255) do |average_range, *xs|
        vals = flatten([average_range]); ranges = xs.each_slice(2).map { |r, c| [flatten([r]), c] }
        if xs.length.odd?
          ErrorValue.new(code: :value)
        else
          average(vals.each_index.filter_map { |i| vals[i] if ranges.all? { |r, c| r[i] && criterion_match?(r[i], c) } }.map { |x| number_or_zero(x) })
        end
      end
    end

    def register_logic_and_text(registry)
      register(registry, "TRUE", 0) { true }
      register(registry, "FALSE", 0) { false }
      register(registry, "AND", 1..255) { |*xs| flatten(xs).all? { |x| truthy?(x) } }
      register(registry, "OR", 1..255) { |*xs| flatten(xs).any? { |x| truthy?(x) } }
      register(registry, "XOR", 1..255) { |*xs| flatten(xs).count { |x| truthy?(x) }.odd? }
      register(registry, "NOT", 1) { |x| !truthy?(x) }
      register(registry, "IF", 2..3) { |test, yes, no = false| truthy?(test) ? yes : no }
      register(registry, "IFERROR", 2) { |x, fallback| x.is_a?(ErrorValue) ? fallback : x }
      register(registry, "IFNA", 2) { |x, fallback| x.is_a?(ErrorValue) && x.code == :na ? fallback : x }
      register(registry, "IFS", 2..255) do |*xs|
        pair = xs.each_slice(2).find { |test, _| truthy?(test) }
        pair ? pair[1] : ErrorValue.new(code: :na)
      end
      register(registry, "SWITCH", 3..255) do |value, *xs|
        pairs = xs[0...-1].each_slice(2).to_a
        (pairs.find { |match, _| compare(value, match).zero? }&.last) || (xs.length.odd? ? xs.last : ErrorValue.new(code: :na))
      end
      register(registry, "CONCAT", 1..255) { |*xs| flatten(xs).map { |x| text(x) }.join }
      register(registry, "CONCATENATE", 1..255) { |*xs| xs.map { |x| text(x) }.join }
      register(registry, "TEXTJOIN", 3..255) do |delimiter, ignore_empty, *xs|
        flatten(xs).reject { |x| truthy?(ignore_empty) && (x.nil? || x == "") }.map { |x| text(x) }.join(text(delimiter))
      end
      register(registry, "EXACT", 2) { |a, b| text(a) == text(b) }
      register(registry, "LEFT", 1..2) { |s, n = 1| text(s)[0, integer!(n)] || "" }
      register(registry, "RIGHT", 1..2) { |s, n = 1| text(s)[-integer!(n), integer!(n)] || "" }
      register(registry, "MID", 3) { |s, start, count| text(s)[[integer!(start) - 1, 0].max, integer!(count)] || "" }
      register(registry, "LEN", 1) { |s| text(s).length }
      register(registry, "LOWER", 1) { |s| text(s).downcase }
      register(registry, "UPPER", 1) { |s| text(s).upcase }
      register(registry, "PROPER", 1) { |s| text(s).downcase.gsub(/\b[a-z]/) { |c| c.upcase } }
      register(registry, "TRIM", 1) { |s| text(s).strip.gsub(/[ \t]+/, " ") }
      register(registry, "CLEAN", 1) { |s| text(s).delete("\x00-\x1F") }
      register(registry, "REPT", 2) { |s, n| text(s) * [[integer!(n), 0].max, 32_767].min }
      register(registry, "FIND", 2..3) { |find, within, start = 1| (text(within).index(text(find), [integer!(start) - 1, 0].max) || ErrorValue.new(code: :value)).then { |i| i.is_a?(Integer) ? i + 1 : i } }
      register(registry, "SEARCH", 2..3) do |find, within, start = 1|
        offset = [integer!(start) - 1, 0].max
        source = wildcard_regex(text(find)).source[2...-2]
        match = /#{source}/i.match(text(within), offset)
        match ? match.begin(0) + 1 : ErrorValue.new(code: :value)
      end
      register(registry, "REPLACE", 4) { |old, start, count, new_text| text(old).dup.tap { |s| s[integer!(start) - 1, integer!(count)] = text(new_text) } }
      register(registry, "SUBSTITUTE", 3..4) do |old, find, replacement, instance = nil|
        s = text(old); from = text(find); to = text(replacement)
        if instance
          count = 0
          s.gsub(Regexp.new(Regexp.escape(from))) { |match| count += 1; count == integer!(instance) ? to : match }
        else
          s.gsub(from, to)
        end
      end
      register(registry, "TEXT", 2) { |x, pattern| Format.apply(x, Format.parse(text(pattern))).first }
      register(registry, "VALUE", 1) { |s| number!(text(s).delete(",")) }
      register(registry, "CHAR", 1) { |x| integer!(x).clamp(1, 255).chr(Encoding::ISO_8859_1).encode(Encoding::UTF_8) }
      register(registry, "CODE", 1) { |x| text(x).ord }
      register(registry, "UNICHAR", 1) { |x| [integer!(x)].pack("U") }
      register(registry, "UNICODE", 1) { |x| text(x).ord }
    end

    def register_dates(registry)
      register(registry, "DATE", 3) do |year, month, day|
        y = integer!(year); y += 1900 if y.between?(0, 1899)
        month_index = y * 12 + integer!(month) - 1
        normalized_year, normalized_month = month_index.divmod(12)
        Date.new(normalized_year, normalized_month + 1, 1) + integer!(day) - 1
      end
      register(registry, "DATEVALUE", 1) { |s| date_serial(Date.parse(text(s))) }
      register(registry, "DAY", 1) { |x| date_value(x).day }
      register(registry, "MONTH", 1) { |x| date_value(x).month }
      register(registry, "YEAR", 1) { |x| date_value(x).year }
      register(registry, "DAYS", 2) { |end_date, start_date| (date_value(end_date) - date_value(start_date)).to_i }
      register(registry, "DAYS360", 2..3) do |start_date, end_date, method = false|
        a = date_value(start_date); b = date_value(end_date)
        d1 = truthy?(method) ? [a.day, 30].min : (a.day == 31 ? 30 : a.day)
        d2 = truthy?(method) ? [b.day, 30].min : (b.day == 31 && d1 == 30 ? 30 : b.day)
        (b.year - a.year) * 360 + (b.month - a.month) * 30 + d2 - d1
      end
      register(registry, "EDATE", 2) { |d, months| date_value(d) >> integer!(months) }
      register(registry, "EOMONTH", 2) do |d, months|
        target = date_value(d) >> integer!(months)
        target.next_month - target.next_month.day
      end
      register(registry, "HOUR", 1) { |x| (serial_fraction(x) * 24).floor }
      register(registry, "MINUTE", 1) { |x| (serial_fraction(x) * 1440).floor % 60 }
      register(registry, "SECOND", 1) { |x| (serial_fraction(x) * 86_400).floor % 60 }
      register(registry, "TIME", 3) { |h, m, s| ((integer!(h) * 3600 + integer!(m) * 60 + integer!(s)) % 86_400) / 86_400.0 }
      register(registry, "TIMEVALUE", 1) { |s| t = Time.parse(text(s)); (t.hour * 3600 + t.min * 60 + t.sec) / 86_400.0 }
      register(registry, "TODAY", 0, volatile: true) { Date.today }
      register(registry, "NOW", 0, volatile: true) { Time.now }
      register(registry, "WEEKDAY", 1..2) { |d, type = 1| weekday(date_value(d), integer!(type)) }
      register(registry, "WEEKNUM", 1..2) { |d, type = 1| date_value(d).strftime("%U").to_i + 1 + (integer!(type) == 2 ? 0 : 0) }
      register(registry, "ISOWEEKNUM", 1) { |d| date_value(d).cweek }
      register(registry, "NETWORKDAYS", 2..3) do |start, finish, holidays = []|
        holidays = flatten([holidays]).map { |d| date_value(d) }.to_set
        a = date_value(start); b = date_value(finish); sign = a <= b ? 1 : -1
        (([a, b].min)..([a, b].max)).count { |d| ![0, 6].include?(d.wday) && !holidays.include?(d) } * sign
      end
      register(registry, "WORKDAY", 2..3) do |start, days, holidays = []|
        holidays = flatten([holidays]).map { |d| date_value(d) }.to_set
        date = date_value(start); remaining = integer!(days).abs; direction = integer!(days).negative? ? -1 : 1
        while remaining.positive?
          date += direction
          remaining -= 1 unless [0, 6].include?(date.wday) || holidays.include?(date)
        end
        date
      end
      register(registry, "YEARFRAC", 2..3) { |a, b, basis = 0| year_fraction(date_value(a), date_value(b), integer!(basis)) }
    end

    def register_lookup_and_info(registry)
      register(registry, "CHOOSE", 2..255) { |index, *values| values.fetch(integer!(index) - 1) { ErrorValue.new(code: :value) } }
      register(registry, "INDEX", 2..4) do |array, row, column = 1, _area = 1|
        values = matrix(array); values.fetch(integer!(row) - 1) { [] }.fetch(integer!(column) - 1, ErrorValue.new(code: :ref))
      end
      register(registry, "MATCH", 2..3) do |lookup, array, match_type = 0|
        values = flatten([array]); index = if integer!(match_type).zero?
          values.index { |value| compare(value, lookup).zero? }
        else
          candidates = values.each_with_index.select { |value, _| integer!(match_type).positive? ? compare(value, lookup) <= 0 : compare(value, lookup) >= 0 }
          candidates.last&.last
        end
        index ? index + 1 : ErrorValue.new(code: :na)
      end
      register(registry, "VLOOKUP", 3..4) { |lookup, table, column, approximate = false| lookup_table(lookup, table, integer!(column), vertical: true, approximate: truthy?(approximate)) }
      register(registry, "HLOOKUP", 3..4) { |lookup, table, row, approximate = false| lookup_table(lookup, table, integer!(row), vertical: false, approximate: truthy?(approximate)) }
      register(registry, "XLOOKUP", 3..6) do |lookup, lookups, results, _not_found = ErrorValue.new(code: :na), match_mode = 0, _search_mode = 1|
        values = flatten([lookups]); index = values.index { |x| compare(x, lookup).zero? }
        index ? flatten([results])[index] : _not_found
      end
      register(registry, "LOOKUP", 2..3) do |lookup, vector, result = vector|
        v = flatten([vector]); r = flatten([result]); i = v.rindex { |x| compare(x, lookup) <= 0 }
        i ? r[i] : ErrorValue.new(code: :na)
      end
      register(registry, "ADDRESS", 2..5) do |row, column, abs = 1, a1 = true, sheet = nil|
        r = integer!(row); c = integer!(column); mode = integer!(abs)
        if !r.positive? || !c.between?(1, 16_384) || !mode.between?(1, 4)
          ErrorValue.new(code: :value)
        else
          cell = if truthy?(a1)
                   name = Formula.column_name(c)
                   "#{mode == 1 || mode == 3 ? "$#{name}" : name}#{mode == 1 || mode == 2 ? "$" : ""}#{r}"
                 else
                   row_reference = mode == 1 || mode == 2 ? "R#{r}" : "R[#{r}]"
                   column_reference = mode == 1 || mode == 3 ? "C#{c}" : "C[#{c}]"
                   row_reference + column_reference
                 end
          sheet.nil? ? cell : "#{Formula.render_sheet(text(sheet))}!#{cell}"
        end
      end
      register(registry, "ROW", 0..1) { |ref = nil| ref.is_a?(Reference) ? ref.row : 1 }
      register(registry, "COLUMN", 0..1) { |ref = nil| ref.is_a?(Reference) ? ref.column : 1 }
      register(registry, "ROWS", 1) { |x| matrix(x).length }
      register(registry, "COLUMNS", 1) { |x| matrix(x).first&.length || 0 }
      register(registry, "AREAS", 1) { |x| x.is_a?(ArrayValue) ? 1 : ErrorValue.new(code: :value) }
      register(registry, "ISBLANK", 1) { |x| x.nil? }
      register(registry, "ISERR", 1) { |x| x.is_a?(ErrorValue) && x.code != :na }
      register(registry, "ISERROR", 1) { |x| x.is_a?(ErrorValue) }
      register(registry, "ISNA", 1) { |x| x.is_a?(ErrorValue) && x.code == :na }
      register(registry, "ISNUMBER", 1) { |x| numeric?(x) }
      register(registry, "ISTEXT", 1) { |x| x.is_a?(String) }
      register(registry, "ISNONTEXT", 1) { |x| !x.is_a?(String) }
      register(registry, "ISLOGICAL", 1) { |x| x == true || x == false }
      register(registry, "ISEVEN", 1) { |x| integer!(x).even? }
      register(registry, "ISODD", 1) { |x| integer!(x).odd? }
      register(registry, "ISFORMULA", 1) { |x| x.is_a?(String) && x.start_with?("=") }
      register(registry, "N", 1) { |x| x == true ? 1 : x == false || x.nil? || x.is_a?(String) ? 0 : x.is_a?(ErrorValue) ? x : number!(x) }
      register(registry, "NA", 0) { ErrorValue.new(code: :na) }
      register(registry, "TYPE", 1) { |x| x.is_a?(Numeric) ? 1 : x.is_a?(String) ? 2 : x == true || x == false ? 4 : x.is_a?(ErrorValue) ? 16 : 64 }
      register(registry, "ERROR.TYPE", 1) do |x|
        if x.is_a?(ErrorValue)
          { div0: 2, value: 3, ref: 4, name: 5, num: 6, na: 7, spill: 9, calc: 14 }.fetch(x.code, 1)
        else
          ErrorValue.new(code: :na)
        end
      end
      register(registry, "FORMULATEXT", 1) { |x| x.is_a?(String) && x.start_with?("=") ? x : ErrorValue.new(code: :na) }
      register(registry, "HYPERLINK", 1..2) { |url, label = url| text(label) }
      register(registry, "CELL", 1..2) { |info, _ref = nil| text(info).downcase == "filename" ? "" : ErrorValue.new(code: :value) }
      register(registry, "ISREF", 1) { |x| x.is_a?(Reference) || x.is_a?(Area) }
      register(registry, "INDIRECT", 1..2) { |_ref, _a1 = true| ErrorValue.new(code: :ref) }
      register(registry, "OFFSET", 3..5, volatile: true) { |_ref, _rows, _columns, _height = 1, _width = 1| ErrorValue.new(code: :ref) }
      register(registry, "FILTER", 2..3) do |array, include, *fallback|
        rows = matrix(array)
        mask = matrix(include)
        rows = [rows] if !rows.empty? && !rows.first.is_a?(Array)
        mask = [mask] if !mask.empty? && !mask.first.is_a?(Array)
        invalid_matrix = [rows, mask].any? do |values|
          values.empty? || !values.first.is_a?(Array) || values.first.empty? ||
            values.any? { |row| !row.is_a?(Array) || row.length != values.first.length }
        end

        if invalid_matrix
          ErrorValue.new(code: :value)
        else
          by_row = mask.length == rows.length && mask.first.length == 1
          by_column = mask.length == 1 && mask.first.length == rows.first.length
          unless by_row || by_column
            ErrorValue.new(code: :value)
          else
            selectors = by_row ? mask.map(&:first) : mask.first
            error = selectors.find { |value| value.is_a?(ErrorValue) }
            if error
              error
            else
              indices = selectors.each_index.select { |index| truthy?(selectors[index]) }
              if indices.empty?
                fallback.empty? ? ErrorValue.new(code: :calc) : fallback.first
              else
                selected = if by_row
                             indices.map { |index| rows[index] }
                           else
                             rows.map { |row| indices.map { |index| row[index] } }
                           end
                ArrayValue.new(rows: selected)
              end
            end
          end
        end
      end
      register(registry, "TRANSPOSE", 1) { |x| ArrayValue.new(rows: matrix(x).transpose) }
      register(registry, "SEQUENCE", 1..4) do |rows, columns = 1, start = 1, step = 1|
        r = integer!(rows); c = integer!(columns)
        raise RangeError if r <= 0 || c <= 0 || r * c > 1_000_000
        ArrayValue.new(rows: Array.new(r) { |i| Array.new(c) { |j| number!(start) + (i * c + j) * number!(step) } })
      end
      register(registry, "SORT", 1..4) do |x, index = 1, order = 1, by_column = false|
        rows = matrix(x)
        columns = truthy?(by_column)
        items = columns ? rows.transpose : rows
        sorted = items.sort_by { |item| item[integer!(index) - 1] }
        sorted.reverse! if integer!(order).negative?
        ArrayValue.new(rows: columns ? sorted.transpose : sorted)
      end
      unique = lambda do |array, by_col = false, exactly_once = false|
        rows = matrix(array)
        rows = rows.map { |value| [value] } if array.is_a?(Array) && !array.first.is_a?(Array)
        invalid_matrix = rows.empty? || !rows.first.is_a?(Array) || rows.first.empty? ||
          rows.any? { |row| !row.is_a?(Array) || row.length != rows.first.length }
        valid_flags = [true, false, 0, 1].include?(by_col) && [true, false, 0, 1].include?(exactly_once)

        if invalid_matrix || !valid_flags
          ErrorValue.new(code: :value)
        else
          columns = by_col == true || by_col == 1
          only_once = exactly_once == true || exactly_once == 1
          items = columns ? rows.transpose : rows
          counts = items.tally
          unique = items.uniq
          unique.select! { |item| counts.fetch(item) == 1 } if only_once
          unique.empty? ? ErrorValue.new(code: :calc) : ArrayValue.new(rows: columns ? unique.transpose : unique)
        end
      end
      registry.register("UNIQUE", arity: 1..3, &unique)
    end

    def register_finance(registry)
      register(registry, "FV", 3..5) do |rate, periods, payment, present = 0, timing = 0|
        r = number!(rate); n = number!(periods); pmt = number!(payment); pv = number!(present); type = number!(timing)
        r.zero? ? -(pv + pmt * n) : -(pv * (1 + r)**n + pmt * (1 + r * type) * ((1 + r)**n - 1) / r)
      end
      register(registry, "PV", 3..5) do |rate, periods, payment, future = 0, timing = 0|
        r = number!(rate); n = number!(periods); pmt = number!(payment); fv = number!(future); type = number!(timing)
        r.zero? ? -fv - pmt * n : -(fv + pmt * (1 + r * type) * ((1 + r)**n - 1) / r) / (1 + r)**n
      end
      register(registry, "PMT", 3..5) do |rate, periods, present, future = 0, timing = 0|
        r = number!(rate); n = number!(periods); pv = number!(present); fv = number!(future); type = number!(timing)
        r.zero? ? -(pv + fv) / n : -(r * (fv + pv * (1 + r)**n)) / ((1 + r * type) * ((1 + r)**n - 1))
      end
      register(registry, "NPER", 3..5) do |rate, payment, present, future = 0, timing = 0|
        r = number!(rate); pmt = number!(payment); pv = number!(present); fv = number!(future); type = number!(timing)
        r.zero? ? -(pv + fv) / pmt : Math.log((pmt * (1 + r * type) - fv * r) / (pv * r + pmt * (1 + r * type))) / Math.log(1 + r)
      end
      register(registry, "NPV", 2..255) do |rate, *values|
        r = number!(rate); numeric_values(values).each_with_index.sum { |value, i| value / ((1 + r)**(i + 1)) }
      end
      register(registry, "IRR", 1..2) { |values, _guess = 0.1| irr(numeric_values([values])) }
      register(registry, "MIRR", 3) { |values, finance, reinvestment| mirr(numeric_values([values]), number!(finance), number!(reinvestment)) }
      register(registry, "RATE", 3..6) { |periods, payment, present, future = 0, timing = 0, guess = 0.1| rate(number!(periods), number!(payment), number!(present), number!(future), number!(timing), number!(guess)) }
      register(registry, "SLN", 3) { |cost, salvage, life| (number!(cost) - number!(salvage)) / number!(life) }
      register(registry, "SYD", 4) { |cost, salvage, life, period| 2 * (number!(cost) - number!(salvage)) * (number!(life) - number!(period) + 1) / (number!(life) * (number!(life) + 1)) }
      register(registry, "DDB", 4..5) { |cost, salvage, life, period, factor = 2| ddb(number!(cost), number!(salvage), number!(life), number!(period), number!(factor)) }
      register(registry, "DB", 4..5) { |cost, salvage, life, period, month = 12| (number!(cost) - number!(salvage)) * (1 - (number!(salvage) / number!(cost))**(1 / number!(life))).round(3) * (integer!(period) == 1 ? integer!(month) / 12.0 : 1) }
      register(registry, "EFFECT", 2) { |nominal, periods| (1 + number!(nominal) / integer!(periods))**integer!(periods) - 1 }
      register(registry, "NOMINAL", 2) { |effective, periods| integer!(periods) * ((1 + number!(effective))**(1 / integer!(periods)) - 1) }
    end

    def register(registry, name, arity, volatile: false, &block)
      registry.register(name, arity: arity, volatile: volatile, &block)
    end

    def flatten(values)
      values.flat_map do |value|
        case value
        when ArrayValue then value.rows.flatten
        when Array then value.flatten
        else [value]
        end
      end
    end

    def numeric_values(values)
      flatten(values).filter_map do |value|
        case value
        when Numeric then value
        when Date then date_serial(value)
        when Time then date_serial(value.to_date) + serial_fraction(value)
        when true then 1
        when false, nil, String, ErrorValue then nil
        else nil
        end
      end
    end

    def number!(value)
      return value if value.is_a?(Numeric)
      return 1 if value == true
      return 0 if value == false || value.nil?
      return date_serial(value) if value.is_a?(Date)
      return Float(value) if value.is_a?(String) && value.strip.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?\z/i)

      raise ArgumentError, "not numeric"
    end

    def integer!(value) = number!(value).to_i
    def numeric?(value) = value.is_a?(Numeric) || value.is_a?(Date) || value.is_a?(Time)
    def number_or_zero(value) = value.nil? ? 0 : (value.is_a?(ErrorValue) ? 0 : number!(value))
    def text(value) = value.nil? ? "" : value == true ? "TRUE" : value == false ? "FALSE" : value.to_s
    def truthy?(value) = !(value.nil? || value == false || value == 0 || value == "")
    def average(values) = values.empty? ? ErrorValue.new(code: :div0) : values.sum.to_f / values.length
    def median(values) = values.empty? ? ErrorValue.new(code: :num) : values.sort.then { |a| a.length.odd? ? a[a.length / 2] : (a[a.length / 2 - 1] + a[a.length / 2]) / 2.0 }

    def deviation(values, sample:)
      denominator = values.length - (sample ? 1 : 0)
      return ErrorValue.new(code: sample && denominator < 1 ? :div0 : :num) unless denominator.positive?

      mean = values.sum.to_f / values.length
      Math.sqrt(values.sum { |x| (x - mean)**2 } / denominator)
    end

    def factorial(value)
      n = Integer(value)
      raise RangeError if n.negative? || n > 170
      (1..n).reduce(1, :*)
    end

    def double_factorial(value)
      n = Integer(value)
      raise RangeError if n.negative? || n > 300
      (1..n).select { |x| (x - n).even? }.reduce(1, :*)
    end

    def choose(n, k)
      return 0 if k.negative? || k > n
      return 0 if n.negative? || n > 10_000

      k = [k, n - k].min
      (1..k).reduce(1) { |value, i| value * (n - k + i) / i }
    end

    def round_multiple(value, multiple)
      raise ZeroDivisionError if multiple.zero?
      (value.fdiv(multiple).round) * multiple
    end

    def truncate_decimal(value, digits)
      factor = 10.0**digits
      (value * factor).truncate / factor
    end

    def round_up(value, digits)
      factor = 10.0**digits
      ((value * factor).abs.ceil * (value.negative? ? -1 : 1)) / factor
    end

    def floor_ceiling(value, significance, ceiling, mode)
      raise ZeroDivisionError if significance.zero?
      return 0 if value.zero?
      quotient = value.fdiv(significance)
      if ceiling
        (value.negative? && mode != 0 ? quotient.floor : quotient.ceil) * significance
      else
        (value.negative? && mode != 0 ? quotient.ceil : quotient.floor) * significance
      end
    end

    def comparable_values(values)
      flatten(values).filter_map { |x| x == true ? 1 : x == false || x.nil? || x.is_a?(String) ? 0 : (number!(x) rescue nil) }
    end

    def criterion_match?(value, criteria)
      return false if value.is_a?(ErrorValue)
      criterion = text(criteria)
      operator, target = criterion.match(/\A(<=|>=|<>|=|<|>)(.*)\z/)&.captures || ["=", criterion]
      if %w[< <= > >= <>].include?(operator)
        left = value.is_a?(Numeric) ? value : text(value).downcase
        right = target.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/) ? target.to_f : target.downcase
        comparison = left <=> right
        return false unless comparison
        return { "<" => comparison.negative?, "<=" => !comparison.positive?, ">" => comparison.positive?, ">=" => !comparison.negative?, "<>" => !comparison.zero? }.fetch(operator)
      end
      return value.nil? || value == "" if target == ""
      regex = wildcard_regex(target)
      text(value).casecmp?(target) || text(value).match?(regex)
    end

    def wildcard_regex(pattern)
      source = Regexp.escape(pattern).gsub("~\\*", "\\*").gsub("~\\?", "\\?").gsub("\\*", ".*").gsub("\\?", ".")
      /\A#{source}\z/i
    end

    def compare(left, right)
      left = left.nil? ? 0 : left
      right = right.nil? ? 0 : right
      if left.is_a?(Numeric) && right.is_a?(Numeric)
        left <=> right
      else
        text(left).downcase <=> text(right).downcase
      end
    end

    def matrix(value)
      value.is_a?(ArrayValue) ? value.rows : value.is_a?(Array) ? value : [[value]]
    end

    def lookup_table(lookup, table, index, vertical:, approximate: false)
      rows = matrix(table)
      return ErrorValue.new(code: :ref) unless index.positive?
      lookup_values = vertical ? rows.map(&:first) : rows.first
      result_values = vertical ? rows.map { |row| row[index - 1] } : (rows[index - 1] || [])
      found = lookup_values.index { |value| compare(value, lookup).zero? }
      found ||= lookup_values.each_index.select { |i| compare(lookup_values[i], lookup) <= 0 }.last if approximate
      found ? result_values[found] : ErrorValue.new(code: :na)
    end

    def date_serial(value) = (value.to_date - Date.new(1899, 12, 30)).to_i
    def date_value(value) = value.is_a?(Date) ? value : Date.new(1899, 12, 30) + number!(value).to_i
    def serial_fraction(value) = value.is_a?(Time) ? (value.hour * 3600 + value.min * 60 + value.sec + value.nsec / 1e9) / 86_400.0 : number!(value) % 1
    def weekday(date, type) = type == 2 ? ((date.wday + 6) % 7) + 1 : type == 3 ? (date.wday + 6) % 7 : date.wday + 1
    def year_fraction(a, b, basis) = basis == 1 ? (b - a).to_i / (a.leap? ? 366.0 : 365.0) : (b.year - a.year) + (b.yday - a.yday) / 365.0

    def irr(values)
      guess = 0.1
      100.times do
        value = values.each_with_index.sum { |cash, i| cash / (1 + guess)**i }
        derivative = values.each_with_index.sum { |cash, i| i.zero? ? 0 : -i * cash / (1 + guess)**(i + 1) }
        return guess if value.abs < 1e-9
        return ErrorValue.new(code: :num) if derivative.zero?

        guess -= value / derivative
      end
      ErrorValue.new(code: :num)
    end

    def mirr(values, finance, reinvestment)
      n = values.length
      positive = values.each_with_index.sum { |x, i| x.positive? ? x * (1 + reinvestment)**(n - i - 1) : 0 }
      negative = values.each_with_index.sum { |x, i| x.negative? ? x / (1 + finance)**i : 0 }
      (positive / -negative)**(1.0 / (n - 1)) - 1
    end

    def rate(periods, payment, present, future, timing, guess)
      x = guess
      100.times do
        f = x.zero? ? present + payment * periods + future : present * (1 + x)**periods + payment * (1 + x * timing) * ((1 + x)**periods - 1) / x + future
        return x if f.abs < 1e-9
        derivative = (rate_equation(periods, payment, present, future, timing, x + 1e-6) - f) / 1e-6
        return ErrorValue.new(code: :num) if derivative.zero?

        x -= f / derivative
      end
      ErrorValue.new(code: :num)
    end

    def rate_equation(n, pmt, pv, fv, type, rate)
      pv * (1 + rate)**n + pmt * (1 + rate * type) * ((1 + rate)**n - 1) / rate + fv
    end

    def ddb(cost, salvage, life, period, factor)
      raise RangeError unless cost >= 0 && salvage >= 0 && life.positive? && period.positive? && factor.positive?

      book_value = cost
      depreciation = 0.0
      1.upto(integer!(period)) do
        depreciation = [book_value * factor / life.to_f, book_value - salvage].min
        book_value -= depreciation
      end
      depreciation
    end
  end
end
