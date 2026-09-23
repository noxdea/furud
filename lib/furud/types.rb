# frozen_string_literal: true

module Furud
  Reference = Data.define(:sheet, :row, :column, :absolute_row, :absolute_column) do
    def initialize(sheet: nil, row:, column:, absolute_row: false, absolute_column: false)
      raise ArgumentError, "row and column must be positive" unless row.to_i.positive? && column.to_i.positive?

      super(sheet: sheet&.to_s, row: Integer(row), column: Integer(column),
            absolute_row: !!absolute_row, absolute_column: !!absolute_column)
    end
  end

  Area = Data.define(:sheet, :top, :left, :bottom, :right) do
    def initialize(sheet: nil, top:, left:, bottom:, right:)
      values = [top, left, bottom, right].map { |value| Integer(value) }
      raise ArgumentError, "area coordinates must be positive" unless values.all?(&:positive?)

      top, left, bottom, right = values
      super(sheet: sheet&.to_s, top: [top, bottom].min, left: [left, right].min,
            bottom: [top, bottom].max, right: [left, right].max)
    end

    def include?(reference)
      (sheet.nil? || reference.sheet == sheet) && reference.row.between?(top, bottom) &&
        reference.column.between?(left, right)
    end
  end

  ERROR_CODES = { div0: "#DIV/0!", value: "#VALUE!", ref: "#REF!", name: "#NAME?",
                  na: "#N/A", num: "#NUM!", cycle: "#CYCLE!", spill: "#SPILL!",
                  calc: "#CALC!" }.freeze
  ErrorValue = Data.define(:code) do
    def initialize(code:)
      super(code: code.to_sym)
    end

    def to_s = ERROR_CODES.fetch(code, "#VALUE!")
  end

  Node = Data.define(:type, :value, :children) do
    def initialize(type:, value: nil, children: [])
      super(type: type.to_sym, value: value, children: children.freeze)
    end
  end

  Adjustment = Data.define(:type, :sheet, :at, :count) do
    def initialize(type:, sheet: nil, at:, count: 1)
      type = type.to_sym
      raise ArgumentError, "type must be insert_rows, delete_rows, insert_columns, or delete_columns" unless
        %i[insert_rows delete_rows insert_columns delete_columns].include?(type)
      raise ArgumentError, "at and count must be positive" unless Integer(at).positive? && Integer(count).positive?

      super(type: type, sheet: sheet&.to_s, at: Integer(at), count: Integer(count))
    end
  end

  ArrayValue = Data.define(:rows) do
    def initialize(rows:)
      rows = rows.map { |row| row.dup.freeze }.freeze
      raise ArgumentError, "array must not be empty" if rows.empty? || rows.any?(&:empty?)
      raise ArgumentError, "array rows must have equal length" unless rows.map(&:length).uniq.one?

      super(rows: rows)
    end

    def height = rows.length
    def width = rows.first.length
    def [](row, column) = rows[row][column]
  end
end
