# frozen_string_literal: true

require "date"

module Furud
  module Format
    Section = Data.define(:pattern, :condition, :color)
    Spec = Data.define(:sections, :locale)
    DATE_TOKENS = %w[yyyy yy mmmm mmm mm m dddd ddd dd d hh h ss s].sort_by { |token| -token.length }.freeze
    LOCALE_MARKS = {
      en: [".", ","], ja: [".", ","], de: [",", "."], es: [",", "."],
      it: [",", "."], fr: [",", "\u202f"], pt: [",", "."]
    }.freeze

    module_function

    def parse(pattern, locale: :en)
      sections = split_sections(pattern.to_s).first(4).map do |section|
        condition_match = section.match(/\[(<=|>=|<>|=|<|>)(-?\d+(?:\.\d+)?)\]/)
        color = section.match(/\[(black|blue|cyan|green|magenta|red|white|yellow|color\d+)\]/i)&.captures&.first&.downcase
        cleaned = section.gsub(/\[(?:<=|>=|<>|=|<|>)-?\d+(?:\.\d+)?\]/, "")
                         .gsub(/\[(?:black|blue|cyan|green|magenta|red|white|yellow|color\d+)\]/i, "")
        Section.new(pattern: cleaned, condition: condition_match && [condition_match[1], condition_match[2].to_f], color: color&.to_sym)
      end
      Spec.new(sections: sections.freeze, locale: locale.to_sym)
    end

    def apply(value, spec)
      return [value.to_s, {}] if value.is_a?(ErrorValue)
      return ["", {}] if value.nil?

      section, index = select_section(value, spec.sections)
      style = { section: index }
      style[:color] = section.color if section&.color
      return [text_format(value, section&.pattern), style] if value.is_a?(String)

      pattern = section&.pattern.to_s
      if date_pattern?(pattern)
        date = if value.is_a?(Time)
                 value
               elsif value.is_a?(Date)
                 value
               else
                 serial = numeric(value)
                 base = Date.new(1899, 12, 30) + serial.floor
                 seconds = ((serial % 1) * 86_400).round
                 Time.utc(base.year, base.month, base.day) + seconds
               end
        return [format_date(date, pattern), style]
      end

      [format_number(value, pattern, spec.locale, index), style]
    rescue ArgumentError, TypeError, RangeError
      [value.to_s, style || {}]
    end

    # Returns [inferred_value, Excel format pattern].
    def infer(text, locale: :en)
      value = text.to_s.strip
      return [value, "@"] if value.empty?
      return [value.casecmp?("true"), "General"] if %w[true false].include?(value.downcase)
      return [Date.iso8601(value), "yyyy-mm-dd"] if value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.valid_date?(*value.split("-").map(&:to_i))

      decimal, group = LOCALE_MARKS.fetch(locale.to_sym, LOCALE_MARKS[:en])
      normalized = value.delete(group).sub(decimal, ".")
      if normalized.match?(/\A[+-]?(?:\d+|\d*\.\d+)%?\z/)
        percent = normalized.delete_suffix("%").to_f
        return [value.end_with?("%") ? percent / 100 : (normalized.include?(".") ? normalized.to_f : normalized.to_i), value.end_with?("%") ? "0.00%" : normalized.include?(".") ? "0.00" : "#,##0"]
      end
      [text, "@"]
    end

    def split_sections(pattern)
      sections = []
      current = +""
      quoted = false
      bracket = false
      escaped = false
      pattern.each_char do |char|
        if escaped
          current << char
          escaped = false
        elsif char == "\\"
          current << char
          escaped = true
        elsif char == '"' && !bracket
          quoted = !quoted
          current << char
        elsif char == "[" && !quoted
          bracket = true
          current << char
        elsif char == "]" && bracket
          bracket = false
          current << char
        elsif char == ";" && !quoted && !bracket
          sections << current
          current = +""
        else
          current << char
        end
      end
      sections << current
      sections
    end

    def select_section(value, sections)
      return [nil, 0] if sections.empty?

      conditional = sections.each_with_index.find do |section, _index|
        section.condition && condition_match?(value, *section.condition)
      end
      return conditional if conditional
      if sections.any?(&:condition)
        fallback = sections.each_with_index.find { |section, _index| !section.condition }
        return fallback if fallback
        return [nil, 0]
      end

      index = if value.is_a?(String)
                3
              elsif value.is_a?(Numeric) && value.negative?
                [1, sections.length - 1].min
              elsif value == 0
                [2, sections.length - 1].min
              else
                0
              end
      [sections[index], index]
    end

    def condition_match?(value, operator, target)
      value = numeric(value)
      { "<" => value < target, "<=" => value <= target, ">" => value > target,
        ">=" => value >= target, "=" => value == target, "<>" => value != target }.fetch(operator)
    end

    def format_number(value, pattern, locale, section_index)
      value = numeric(value)
      pattern = "General" if pattern.empty?
      return general_number(value) if pattern.casecmp?("General")

      raw = unquote(pattern.gsub(/\[(?:h+|m+|s+)\]/i, ""))
      if raw.include?("%")
        value *= 100
      elsif raw.include?("‰")
        value *= 1000
      end
      placeholders = raw.match(/[0#?][0#?,]*(?:\.[0#?]+)?(?:[Ee][+-]?[0#?]+)?/)
      return raw.gsub("@", value.to_s) unless placeholders

      number_pattern = placeholders[0]
      integer_pattern, fractional_pattern = number_pattern.split(".", 2)
      fractional_pattern = fractional_pattern&.sub(/[Ee].*/, "")
      decimals = fractional_pattern&.length.to_i
      rendered = format("%.#{decimals}f", value.abs)
      integer, fraction = rendered.split(".", 2)
      grouped = integer_pattern.include?(",") ? group_integer(integer, locale) : integer
      optional_decimals = fractional_pattern.to_s[/#+\z/]&.length.to_i
      if optional_decimals.positive?
        fraction = fraction.sub(/0{1,#{optional_decimals}}\z/, "")
      end
      decimal_mark, = LOCALE_MARKS.fetch(locale.to_sym, LOCALE_MARKS[:en])
      number = fraction.to_s.empty? ? grouped : "#{grouped}#{decimal_mark}#{fraction}"
      prefix = raw[0...placeholders.begin(0)]
      suffix = raw[placeholders.end(0)..]
      number = "-#{number}" if value.negative? && section_index.zero? && !unquote(prefix).match?(/[-(]/)
      (unquote(prefix) + number + unquote(suffix)).gsub("\\", "")
    end

    def group_integer(integer, locale)
      group = LOCALE_MARKS.fetch(locale.to_sym, LOCALE_MARKS[:en])[1]
      integer.reverse.scan(/.{1,3}/).join(group).reverse
    end

    def date_pattern?(pattern)
      unquote(pattern).match?(/(?:y{2,4}|d{1,4}|m{1,4}|h{1,2}|s{1,2}|AM\/PM)/i)
    end

    def format_date(value, pattern)
      date = value.is_a?(Time) ? value.to_date : value
      pattern = unquote(pattern)
      hour = value.respond_to?(:hour) ? value.hour : 0
      minute = value.respond_to?(:min) ? value.min : 0
      second = value.respond_to?(:sec) ? value.sec : 0
      tokens = DATE_TOKENS.to_h do |token|
        value = case token
                when "yyyy" then date.strftime("%Y")
                when "yy" then date.strftime("%y")
                when "mmmm" then date.strftime("%B")
                when "mmm" then date.strftime("%b")
                when "mm", "m" then date.strftime("%m")
                when "dddd" then date.strftime("%A")
                when "ddd" then date.strftime("%a")
                when "dd" then date.strftime("%d")
                when "d" then date.strftime("%-d")
                when "hh" then format("%02d", hour)
                when "h" then hour.to_s
                when "ss" then format("%02d", second)
                when "s" then second.to_s
                else token
                end
        [token, value]
      end
      pattern.gsub(/AM\/PM|yyyy|yy|mmmm|mmm|mm|m|dddd|ddd|dd|d|hh|h|ss|s/i) do |token|
        next (hour < 12 ? "AM" : "PM") if token.casecmp?("AM/PM")

        if %w[m mm].include?(token.downcase)
          before = Regexp.last_match.pre_match[-1]
          after = Regexp.last_match.post_match[0]
          if before == ":" || after == ":"
            format(token.length == 2 ? "%02d" : "%d", minute)
          else
            tokens.fetch(token.downcase, token)
          end
        else
          tokens.fetch(token.downcase, token)
        end
      end
    end

    def text_format(value, pattern)
      return value.to_s if pattern.nil? || pattern.empty? || pattern.casecmp?("General")

      unquote(pattern).gsub("@", value.to_s)
    end

    def unquote(pattern)
      pattern.gsub(/"([^"]*)"/) { Regexp.last_match(1) }
    end

    def numeric(value)
      return value.to_f if value.is_a?(Integer)
      return value if value.is_a?(Numeric)
      return value.to_time.to_f if value.is_a?(Time)
      return (value - Date.new(1899, 12, 30)).to_i if value.is_a?(Date)

      Float(value)
    end

    def general_number(value)
      value.to_i == value ? value.to_i.to_s : value.to_s
    end
  end
end
