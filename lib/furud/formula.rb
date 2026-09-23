# frozen_string_literal: true

require "strscan"

module Furud
  module Formula
    Token = Data.define(:type, :value, :position)
    COLUMNS = (1..16_384).to_h do |number|
      value = number
      name = +""
      while value.positive?
        value, remainder = (value - 1).divmod(26)
        name.prepend((65 + remainder).chr)
      end
      [name, number]
    end.freeze
    COLUMN_NAMES = COLUMNS.invert.freeze
    ERROR_CODES = Furud::ERROR_CODES.to_h { |code, text| [text.upcase, code] }.freeze

    module_function

    def parse(source, origin: nil)
      Parser.new(source.to_s, origin: coerce_reference(origin)).parse
    end

    def render(ast, origin: nil)
      "=#{render_node(ast, coerce_reference(origin))}"
    end

    def references(ast)
      result = []
      collect = lambda do |node|
        case node.type
        when :reference, :qualified_reference
          result << node.value
        when :range
          first, last = node.children.map(&:value)
          result << Area.new(sheet: first.sheet || last.sheet,
                             top: first.row, left: first.column,
                             bottom: last.row, right: last.column)
        else
          node.children.each { |child| collect.call(child) }
        end
      end
      collect.call(ast)
      result.uniq
    end

    def translate(ast, from:, to:)
      from = coerce_reference(from)
      to = coerce_reference(to)
      transform(ast) do |node|
        case node.type
        when :range
          children = node.children.map { |child| translate_reference(child, from, to) }
          children.any? { |child| child.type == :error } ? ref_error_node : Node.new(type: :range, children: children)
        when :reference, :qualified_reference
          translate_reference(node, from, to)
        else
          node
        end
      end
    end

    def adjust(ast, operation)
      operation = normalize_adjustment(operation)
      adjust_node(ast, operation)
    end

    def coerce_reference(reference)
      case reference
      when Reference then reference
      when Hash
        Reference.new(sheet: reference[:sheet] || reference["sheet"],
                      row: reference[:row] || reference["row"] || 1,
                      column: reference[:column] || reference["column"] || 1,
                      absolute_row: reference[:absolute_row] || reference["absolute_row"],
                      absolute_column: reference[:absolute_column] || reference["absolute_column"])
      when nil then Reference.new(sheet: nil, row: 1, column: 1)
      else raise ArgumentError, "origin must be a Furud::Reference, Hash, or nil"
      end
    end

    def column_number(name)
      COLUMNS[name.upcase]
    end

    def column_name(number)
      COLUMN_NAMES.fetch(number) { raise ParseError, "column outside A:XFD" }
    end

    def render_reference(reference)
      prefix = reference.sheet ? "#{render_sheet(reference.sheet)}!" : ""
      row = reference.absolute_row ? "$#{reference.row}" : reference.row.to_s
      column = reference.absolute_column ? "$#{column_name(reference.column)}" : column_name(reference.column)
      "#{prefix}#{column}#{row}"
    end

    def render_reference_for(reference, origin)
      render_reference(reference.sheet == origin.sheet ? reference.with(sheet: nil) : reference)
    end

    def render_node(node, origin, parent_precedence = 0)
      case node.type
      when :literal then render_literal(node.value)
      when :reference then render_reference_for(node.value, origin)
      when :qualified_reference then render_reference(node.value)
      when :range
        first, last = node.children
        if last.type == :reference && first.value.sheet == last.value.sheet
          last = Node.new(type: :reference, value: last.value.with(sheet: nil))
        end
        "#{render_node(first, origin, 100)}:#{render_node(last, origin, 100)}"
      when :name then node.value
      when :error then node.value.to_s
      when :array
        "{" + node.children.map { |row| row.children.map { |child| render_node(child, origin) }.join(",") }.join(";") + "}"
      when :call
        "#{node.value}(#{node.children.map { |child| render_node(child, origin) }.join(",")})"
      when :unary
        op = node.value
        child = render_node(node.children.first, origin, 60)
        wrap("#{op}#{child}", 60, parent_precedence)
      when :postfix
        wrap("#{render_node(node.children.first, origin, 70)}%", 70, parent_precedence)
      when :binary
        precedence = PRECEDENCE.fetch(node.value)
        left, right = node.children
        right_precedence = precedence + (node.value == "^" ? 0 : 1)
        wrap("#{render_node(left, origin, precedence)}#{node.value}#{render_node(right, origin, right_precedence)}",
             precedence, parent_precedence)
      else raise Error, "unknown formula node: #{node.type}"
      end
    end

    PRECEDENCE = { "=" => 10, "<>" => 10, "<" => 10, ">" => 10, "<=" => 10, ">=" => 10,
                   "&" => 20, "+" => 30, "-" => 30, "*" => 40, "/" => 40, "^" => 50 }.freeze

    def visit(node, &block)
      yield node
      node.children.each { |child| visit(child, &block) }
    end

    def transform(node, &block)
      replaced = block.call(node)
      return replaced unless replaced.equal?(node)

      children = node.children.map { |child| transform(child, &block) }
      children == node.children ? node : Node.new(type: node.type, value: node.value, children: children)
    end

    def translate_reference(node, from, to)
      reference = node.value
      row = reference.absolute_row ? reference.row : to.row + reference.row - from.row
      column = reference.absolute_column ? reference.column : to.column + reference.column - from.column
      return ref_error_node if row < 1 || column < 1

      sheet = node.type == :reference && reference.sheet == from.sheet ? to.sheet : reference.sheet
      ref_node(reference.with(row: row, column: column, sheet: sheet), node.type)
    end

    def ref_error_node
      Node.new(type: :error, value: ErrorValue.new(code: :ref))
    end

    def adjust_node(node, operation)
      case node.type
      when :reference, :qualified_reference
        adjust_reference(node.value, operation, node.type)
      when :range
        first_node, last_node = node.children
        first, last = first_node.value, last_node.value
        adjusted = adjust_range(first, last, operation)
        adjusted.is_a?(ErrorValue) ? Node.new(type: :error, value: adjusted) :
          Node.new(type: :range, value: nil, children: [ref_node(adjusted[0], first_node.type), ref_node(adjusted[1], last_node.type)])
      else
        children = node.children.map { |child| adjust_node(child, operation) }
        children == node.children ? node : Node.new(type: node.type, value: node.value, children: children)
      end
    end

    def adjust_reference(reference, operation, node_type)
      axis = operation.type.to_s.end_with?("rows") ? :row : :column
      kind = operation.type.to_s.start_with?("insert") ? :insert : :delete
      return ref_node(reference, node_type) unless operation.sheet.nil? || reference.sheet == operation.sheet

      coordinate = reference.public_send(axis)
      if kind == :insert
        coordinate += operation.count if coordinate >= operation.at
      elsif coordinate >= operation.at && coordinate < operation.at + operation.count
        return Node.new(type: :error, value: ErrorValue.new(code: :ref))
      elsif coordinate >= operation.at + operation.count
        coordinate -= operation.count
      end
      ref_node(reference.with(axis => coordinate), node_type)
    end

    def adjust_range(first, last, operation)
      axis = operation.type.to_s.end_with?("rows") ? :row : :column
      kind = operation.type.to_s.start_with?("insert") ? :insert : :delete
      sheet = first.sheet || last.sheet
      return [first, last] unless operation.sheet.nil? || sheet == operation.sheet

      start = [first.public_send(axis), last.public_send(axis)].min
      finish = [first.public_send(axis), last.public_send(axis)].max
      if kind == :insert
        if operation.at <= start
          start += operation.count
          finish += operation.count
        elsif operation.at <= finish
          finish += operation.count
        end
      else
        deleted_end = operation.at + operation.count - 1
        overlap = [finish, deleted_end].min - [start, operation.at].max + 1
        if overlap >= finish - start + 1
          return ErrorValue.new(code: :ref)
        elsif overlap.positive?
          finish -= overlap
          start = operation.at if start >= operation.at
        elsif start > deleted_end
          start -= operation.count
          finish -= operation.count
        end
      end
      first_value = first.public_send(axis)
      last_value = last.public_send(axis)
      reversed = first_value > last_value
      if axis == :row
        new_first = first.with(row: reversed ? finish : start)
        new_last = last.with(row: reversed ? start : finish)
      else
        new_first = first.with(column: reversed ? finish : start)
        new_last = last.with(column: reversed ? start : finish)
      end
      [new_first, new_last]
    end

    def normalize_adjustment(operation)
      return operation if operation.is_a?(Adjustment)

      values = operation.transform_keys(&:to_sym)
      Adjustment.new(type: values.fetch(:type), sheet: values[:sheet],
                     at: values.fetch(:at), count: values.fetch(:count, 1))
    end

    def ref_node(reference, node_type = :reference)
      return Node.new(type: :error, value: ErrorValue.new(code: :ref)) unless reference.row.between?(1, 1_048_576) && reference.column.between?(1, 16_384)

      Node.new(type: node_type, value: reference)
    end

    def render_literal(value)
      case value
      when String then "\"#{value.gsub('"', '""')}\""
      when true then "TRUE"
      when false then "FALSE"
      else value.to_s
      end
    end

    def render_sheet(sheet)
      return sheet if sheet.match?(/\A[A-Za-z_][A-Za-z0-9_.]*\z/)

      "'#{sheet.gsub("'", "''")}'"
    end

    def wrap(text, precedence, parent_precedence)
      precedence < parent_precedence ? "(#{text})" : text
    end

    class Lexer
      def initialize(source, origin)
        @source = source
        @origin = origin
        @scanner = StringScanner.new(source)
      end

      def tokens
        result = []
        until @scanner.eos?
          @scanner.skip(/\s+/)
          break if @scanner.eos?

          position = @scanner.pos
          result << Token.new(*next_token(position))
        end
        result << Token.new(:eof, nil, @scanner.pos)
      end

      private

      def next_token(position)
        if (raw = @scanner.scan(/'(?:[^']|'')+'!\$?[A-Za-z]{1,3}\$?\d+/))
          sheet, address = raw.split("!", 2)
          return [:qualified_reference, parse_a1(address, sheet[1...-1].gsub("''", "'")), position]
        end
        if (raw = @scanner.scan(/[A-Za-z_][A-Za-z0-9_.]*!\$?[A-Za-z]{1,3}\$?\d+/))
          sheet, address = raw.split("!", 2)
          return [:qualified_reference, parse_a1(address, sheet), position]
        end
        if (raw = @scanner.scan(/R(?:\d+|\[-?\d+\])?C(?:\d+|\[-?\d+\])?/i))
          return [:reference, parse_r1c1(raw), position]
        end
        if (raw = @scanner.scan(/\$?[A-Za-z]{1,3}\$?\d+/))
          if @scanner.rest.match?(/\A\s*\(/)
            return [:identifier, raw, position]
          end
          return [:reference, parse_a1(raw, nil), position]
        end
        if (raw = @scanner.scan(/#(?:DIV\/0!|VALUE!|REF!|NAME\?|N\/A|NUM!|CYCLE!|SPILL!|CALC!)/i))
          code = ERROR_CODES[raw.upcase]
          return [:error, ErrorValue.new(code: code), position]
        end
        if @scanner.scan(/"/)
          value = +""
          until @scanner.eos?
            part = @scanner.scan(/[^\"]+/)
            value << part if part
            break unless @scanner.scan(/"/)
            if @scanner.scan(/"/)
              value << '"'
            else
              return [:string, value, position]
            end
          end
          raise ParseError, "unterminated string at #{position}"
        end
        if (raw = @scanner.scan(/(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?/))
          value = raw.match?(/[.Ee]/) ? Float(raw) : Integer(raw)
          return [:number, value, position]
        end
        if (operator = @scanner.scan(/<=|>=|<>|[+\-*\/^&%=<>:(),;{}]/))
          type = { "(" => :lparen, ")" => :rparen, "," => :separator, ";" => :row_separator,
                   "{" => :lbrace, "}" => :rbrace, ":" => :colon }[operator] || :operator
          return [type, operator, position]
        end
        if (identifier = @scanner.scan(/[A-Za-z_\\][A-Za-z0-9_.\\]*/))
          value = identifier.upcase
          return [:boolean, value == "TRUE", position] if %w[TRUE FALSE].include?(value)

          return [:identifier, identifier, position]
        end

        raise ParseError, "unexpected character #{@scanner.peek(1).inspect} at #{position}"
      end

      def parse_a1(raw, sheet)
        match = /\A(\$?)([A-Za-z]{1,3})(\$?)(\d+)\z/.match(raw)
        column = Formula.column_number(match[2])
        row = Integer(match[4])
        raise ParseError, "cell reference outside A1:XFD1048576: #{raw}" unless column && row.between?(1, 1_048_576)

        Reference.new(sheet: sheet, row: row, column: column,
                      absolute_row: !match[3].empty?, absolute_column: !match[1].empty?)
      end

      def parse_r1c1(raw)
        match = /\AR(?:(\d+)|\[(-?\d+)\])?C(?:(\d+)|\[(-?\d+)\])?\z/i.match(raw)
        row = match[1] ? Integer(match[1]) : @origin.row + (match[2] ? Integer(match[2]) : 0)
        column = match[3] ? Integer(match[3]) : @origin.column + (match[4] ? Integer(match[4]) : 0)
        Reference.new(sheet: @origin.sheet, row: row, column: column,
                      absolute_row: !match[1].nil?, absolute_column: !match[3].nil?)
      rescue ArgumentError
        raise ParseError, "invalid R1C1 reference: #{raw}"
      end
    end

    class Parser
      def initialize(source, origin:)
        @origin = origin
        source = source.sub(/\A\s*=/, "")
        @tokens = Lexer.new(source, origin).tokens
        @index = 0
      end

      def parse
        raise ParseError, "formula is empty" if current.type == :eof

        node = comparison
        raise ParseError, "unexpected token #{current.value.inspect} at #{current.position}" unless current.type == :eof

        qualify_sheets(node, @origin.sheet)
      end

      private

      def comparison
        binary_chain(:concat, %w[= <> < > <= >=])
      end

      def concat
        binary_chain(:additive, ["&"])
      end

      def additive
        binary_chain(:multiplicative, %w[+ -])
      end

      def multiplicative
        binary_chain(:unary, %w[* /])
      end

      def unary
        if current.type == :operator && %w[+ -].include?(current.value)
          op = advance.value
          return Node.new(type: :unary, value: op, children: [unary])
        end

        exponent
      end

      def exponent
        node = postfix
        if accept_operator("^")
          node = Node.new(type: :binary, value: "^", children: [node, unary])
        end
        node
      end

      def postfix
        node = primary
        node = Node.new(type: :range, value: nil, children: [node, reference_primary]) if current.type == :colon && advance
        node = Node.new(type: :postfix, value: "%", children: [node]) while accept_operator("%")
        node
      end

      def primary
        token = advance
        case token.type
        when :number then Node.new(type: :literal, value: token.value)
        when :string then Node.new(type: :literal, value: token.value)
        when :boolean then Node.new(type: :literal, value: token.value)
        when :error then Node.new(type: :error, value: token.value)
        when :reference then Node.new(type: :reference, value: token.value)
        when :qualified_reference then Node.new(type: :qualified_reference, value: token.value)
        when :identifier then identifier(token)
        when :lparen
          node = comparison
          expect(:rparen)
          node
        when :lbrace then array_literal
        else raise ParseError, "expected a value at #{token.position}"
        end
      end

      def reference_primary
        token = advance
        raise ParseError, "range endpoint must be a cell reference at #{token.position}" unless %i[reference qualified_reference].include?(token.type)

        Node.new(type: token.type, value: token.value)
      end

      def qualify_sheets(node, default_sheet)
        if %i[reference qualified_reference].include?(node.type)
          reference = node.value
          return node if node.type == :qualified_reference || reference.sheet
          return Node.new(type: :reference, value: reference.with(sheet: default_sheet))
        end
        if node.type == :range
          first_node, last_node = node.children
          first, last = first_node.value, last_node.value
          first_sheet = first.sheet || default_sheet
          last_sheet = last.sheet || (first_node.type == :qualified_reference ? first_sheet : default_sheet)
          return Node.new(type: :range, value: nil, children: [
            Node.new(type: first_node.type, value: first.with(sheet: first_sheet)),
            Node.new(type: last_node.type, value: last.with(sheet: last_sheet))
          ])
        end

        children = node.children.map { |child| qualify_sheets(child, default_sheet) }
        children == node.children ? node : Node.new(type: node.type, value: node.value, children: children)
      end

      def identifier(token)
        if current.type == :lparen
          advance
          args = []
          unless current.type == :rparen
            loop do
              args << comparison
              break unless current.type == :separator

              advance
            end
          end
          expect(:rparen)
          Node.new(type: :call, value: token.value.delete_prefix("_xlfn.").upcase, children: args)
        else
          Node.new(type: :name, value: token.value)
        end
      end

      def array_literal
        rows = [[]]
        until current.type == :rbrace
          rows.last << comparison
          case current.type
          when :separator then advance
          when :row_separator then advance; rows << []
          when :rbrace then break
          else raise ParseError, "expected array separator at #{current.position}"
          end
        end
        expect(:rbrace)
        raise ParseError, "empty array" if rows.any?(&:empty?)
        raise ParseError, "array rows must have equal length" unless rows.map(&:length).uniq.one?

        Node.new(type: :array, children: rows.map { |row| Node.new(type: :row, children: row) })
      end

      def binary_chain(next_method, operators)
        node = send(next_method)
        while current.type == :operator && operators.include?(current.value)
          operator = advance.value
          node = Node.new(type: :binary, value: operator, children: [node, send(next_method)])
        end
        node
      end

      def accept_operator(value)
        return false unless current.type == :operator && current.value == value

        advance
        true
      end

      def expect(type)
        return advance if current.type == type

        raise ParseError, "expected #{type}, got #{current.type} at #{current.position}"
      end

      def current = @tokens[@index]
      def advance = @tokens[@index].tap { @index += 1 }
    end
  end
end
