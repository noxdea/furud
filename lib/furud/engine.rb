# frozen_string_literal: true

require "set"

module Furud
  class Engine
    ITERATION_FUNCTIONS = %w[NOW TODAY RAND RANDBETWEEN OFFSET].freeze
    ERROR_HANDLING_FUNCTIONS = %w[IFERROR IFNA ISERR ISERROR ISNA ISBLANK ISNUMBER ISTEXT ISNONTEXT ISLOGICAL ISEVEN ISODD ISREF ISFORMULA ERROR.TYPE TYPE].freeze
    REFERENCE_FUNCTIONS = %w[ROW COLUMN ISREF ISFORMULA FORMULATEXT CELL OFFSET].freeze

    attr_reader :source, :locale

    def initialize(source = nil, functions: Functions.standard, locale: :en,
                   iterative: false, max_iterations: 100, epsilon: 0.001)
      @source = source
      @functions = functions
      @locale = locale.to_sym
      @iterative = !!iterative
      @max_iterations = Integer(max_iterations)
      @epsilon = Float(epsilon)
      raise ArgumentError, "max_iterations must be positive" unless @max_iterations.positive?
      raise ArgumentError, "epsilon must be non-negative" if @epsilon.negative?

      @inputs = {}
      @formula_text = {}
      @formulas = {}
      @dynamic_formulas = Set.new
      @volatile_formulas = Set.new
      @evaluating = Set.new
      @values = {}
      @previous_values = {}
      @dirty = Set.new
      @precedents = {}
      @dependents = Hash.new { |hash, key| hash[key] = Set.new }
      @range_dependents = []
      @names = {}
      @cycles = []
      @spill_values = {}
      @spill_refs = Hash.new { |hash, key| hash[key] = Set.new }
      @spill_parents = {}
    end

    def set(reference, input)
      reference = coerce_reference(reference)
      ast = Formula.parse(input, origin: reference) if input.is_a?(String) && input.start_with?("=")
      @previous_values[reference] = @values[reference] unless @previous_values.key?(reference)
      remove_formula(reference)
      @inputs[reference] = input
      if ast
        @formulas[reference] = ast
        @formula_text[reference] = input
        add_formula_edges(reference, ast)
      else
        @formula_text.delete(reference)
        @values[reference] = input
      end
      @dynamic_formulas.each { |cell| mark_dirty(cell) }
      mark_dirty(reference)
      input
    end

    def clear(reference)
      reference = coerce_reference(reference)
      @previous_values[reference] = @values[reference] unless @previous_values.key?(reference)
      remove_formula(reference)
      @inputs.delete(reference)
      @formula_text.delete(reference)
      @values.delete(reference)
      @dynamic_formulas.each { |cell| mark_dirty(cell) }
      mark_dirty(reference)
      nil
    end

    def value(reference)
      reference = coerce_reference(reference)
      recalculate unless @dirty.empty?
      return @spill_values[reference] if @spill_values.key?(reference)
      return @values[reference] if @values.key?(reference)

      source_value(reference)
    end

    def formula(reference)
      @formula_text[coerce_reference(reference)]
    end

    def recalculate
      volatile_references.each { |reference| mark_dirty(reference) }
      return [] if @dirty.empty?

      pending = @dirty.dup
      @dirty.clear
      previous_spills = @spill_values.dup
      pending.each { |reference| @previous_values[reference] = @values[reference] unless @previous_values.key?(reference) }
      cycle_groups = strongly_connected_components(pending)
      @cycles = @cycles.reject { |cycle| cycle.any? { |reference| pending.include?(reference) } } + cycle_groups
      cycle_members = cycle_groups.flatten.to_set

      pending.each { |reference| clear_spill(reference) }

      if @iterative
        cycle_groups.each { |cycle| iterate_cycle(cycle) }
      else
        cycle_members.each { |reference| store_value(reference, ErrorValue.new(code: :cycle)) }
      end

      ordered_formulas(pending, cycle_members).each do |reference|
        evaluate_cell(reference) unless @dirty.include?(reference)
      end
      pending.each { |reference| @previous_values.delete(reference) unless @values.key?(reference) }
      changed = pending.select do |reference|
        previous = @previous_values.delete(reference)
        previous != value_without_recalculation(reference)
      end
      spill_cells = previous_spills.keys | @spill_values.keys
      changed.concat(spill_cells.select { |reference| previous_spills[reference] != @spill_values[reference] })
      changed.uniq.sort_by { |reference| sort_key(reference) }
    end

    def dirty = @dirty.dup
    def cycles = @cycles.map(&:dup)

    def insert_rows(sheet, at, count = 1) = adjust_cells(:insert_rows, sheet, at, count)
    def delete_rows(sheet, at, count = 1) = adjust_cells(:delete_rows, sheet, at, count)
    def insert_columns(sheet, at, count = 1) = adjust_cells(:insert_columns, sheet, at, count)
    def delete_columns(sheet, at, count = 1) = adjust_cells(:delete_columns, sheet, at, count)

    def define_name(name, area)
      normalized = normalize_name(name)
      @names[normalized] = area
      rebuild_formula_graph
      @formulas.each_key { |reference| mark_dirty(reference) }
      area
    end

    def precedents(reference)
      @precedents.fetch(coerce_reference(reference), []).dup
    end

    def dependents(reference)
      reference = coerce_reference(reference)
      direct = @dependents.fetch(reference, Set.new).to_a
      ranged = @range_dependents.filter_map { |area, owner| owner if area.include?(reference) }
      (direct + ranged).uniq.sort_by { |cell| sort_key(cell) }
    end

    private

    def coerce_reference(reference)
      Formula.coerce_reference(reference)
    end

    def remove_formula(reference)
      old_precedents = @precedents.delete(reference) || []
      old_precedents.each do |precedent|
        if precedent.is_a?(Reference)
          @dependents[precedent].delete(reference)
        else
          @range_dependents.delete([precedent, reference])
        end
      end
      @formulas.delete(reference)
      @dynamic_formulas.delete(reference)
      @volatile_formulas.delete(reference)
      @formula_text.delete(reference)
    end

    def add_formula_edges(reference, ast)
      references = (Formula.references(ast) + dynamic_precedents(ast, reference) + name_precedents(ast, reference)).uniq
      @precedents[reference] = references
      @dynamic_formulas.add(reference) if has_dynamic_indirect?(ast)
      @volatile_formulas.add(reference) if volatile_formula?(ast)
      references.each do |precedent|
        if precedent.is_a?(Reference)
          @dependents[precedent].add(reference)
        else
          @range_dependents << [precedent, reference]
        end
      end
    end

    def mark_dirty(reference)
      queue = [reference]
      visited = Set.new
      index = 0
      while index < queue.length
        current = queue[index]
        index += 1
        next if visited.include?(current)

        visited.add(current)
        @dirty.add(current)
        queue.concat(@dependents.fetch(current, Set.new).to_a)
        @range_dependents.each { |area, owner| queue << owner if area.include?(current) }
        @spill_refs.fetch(current, Set.new).each { |spill_ref| queue.concat(@dependents.fetch(spill_ref, Set.new).to_a) }
        queue << @spill_parents[current] if @spill_parents[current]
      end
    end

    def volatile_references
      @volatile_formulas
    end

    def dependencies(reference)
      (@precedents.fetch(reference, []).flat_map do |precedent|
        if precedent.is_a?(Reference)
          [precedent]
        else
          @formulas.keys.select { |candidate| precedent.include?(candidate) }
        end
      end).select { |candidate| @formulas.key?(candidate) }.uniq
    end

    def ordered_formulas(pending, cycle_members)
      ordered = []
      visited = Set.new
      visit = lambda do |reference|
        return if visited.include?(reference) || cycle_members.include?(reference)

        visited.add(reference)
        dependencies(reference).each { |dependency| visit.call(dependency) if pending.include?(dependency) }
        ordered << reference if @formulas.key?(reference)
      end
      pending.select { |reference| @formulas.key?(reference) }.sort_by { |reference| sort_key(reference) }.each { |reference| visit.call(reference) }
      ordered
    end

    def strongly_connected_components(pending)
      formula_cells = pending.select { |reference| @formulas.key?(reference) }.to_set
      index = 0
      indices = {}
      low = {}
      stack = []
      on_stack = Set.new
      components = []
      connect = lambda do |reference|
        indices[reference] = low[reference] = index
        index += 1
        stack << reference
        on_stack.add(reference)
        dependencies(reference).each do |dependency|
          next unless formula_cells.include?(dependency)

          if !indices.key?(dependency)
            connect.call(dependency)
            low[reference] = [low[reference], low[dependency]].min
          elsif on_stack.include?(dependency)
            low[reference] = [low[reference], indices[dependency]].min
          end
        end
        return unless low[reference] == indices[reference]

        component = []
        loop do
          member = stack.pop
          on_stack.delete(member)
          component << member
          break if member == reference
        end
        self_reference = dependencies(reference).include?(reference)
        components << component.sort_by { |cell| sort_key(cell) } if component.length > 1 || self_reference
      end
      formula_cells.sort_by { |reference| sort_key(reference) }.each { |reference| connect.call(reference) unless indices.key?(reference) }
      components
    end

    def evaluate_cell(reference)
      return @values[reference] unless @formulas.key?(reference)
      return ErrorValue.new(code: :cycle) if @evaluating.include?(reference)

      clear_spill(reference)
      @evaluating.add(reference)
      store_result(reference, evaluate(@formulas.fetch(reference), reference))
    ensure
      @evaluating.delete(reference)
    end

    def evaluate(node, origin)
      case node.type
      when :literal then node.value
      when :error then node.value
      when :reference, :qualified_reference then read_cell(node.value)
      when :range then read_range(node, origin)
      when :name then read_name(node.value, origin)
      when :array
        ArrayValue.new(rows: node.children.map { |row| row.children.map { |child| evaluate(child, origin) } })
      when :unary
        value = evaluate(node.children.first, origin)
        return value if value.is_a?(ErrorValue)
        return map_array(value) { |cell| unary(node.value, cell) } if value.is_a?(ArrayValue)

        unary(node.value, value)
      when :postfix
        value = evaluate(node.children.first, origin)
        return value if value.is_a?(ErrorValue)
        return map_array(value) { |cell| Functions.number!(cell) / 100.0 } if value.is_a?(ArrayValue)

        Functions.number!(value) / 100.0
      when :binary
        left = evaluate(node.children[0], origin)
        return left if left.is_a?(ErrorValue)
        right = evaluate(node.children[1], origin)
        return right if right.is_a?(ErrorValue)
        binary(node.value, left, right)
      when :call then evaluate_call(node, origin)
      else ErrorValue.new(code: :value)
      end
    rescue ZeroDivisionError
      ErrorValue.new(code: :div0)
    rescue Math::DomainError, RangeError
      ErrorValue.new(code: :num)
    rescue ArgumentError, TypeError
      ErrorValue.new(code: :value)
    end

    def evaluate_call(node, origin)
      name = node.value
      entry = @functions[name]
      return ErrorValue.new(code: :name) unless entry
      return ErrorValue.new(code: :value) unless entry.accepts?(node.children.length)

      if name == "IF"
        condition = evaluate(node.children[0], origin)
        return condition if condition.is_a?(ErrorValue)
        return evaluate(node.children[Functions.truthy?(condition) ? 1 : 2], origin) if node.children[Functions.truthy?(condition) ? 1 : 2]

        return false
      end
      if %w[IFERROR IFNA].include?(name)
        value = evaluate(node.children[0], origin)
        catch_error = value.is_a?(ErrorValue) && (name == "IFERROR" || value.code == :na)
        return catch_error ? evaluate(node.children[1], origin) : value
      end
      if name == "IFS"
        node.children.each_slice(2) do |condition_node, result_node|
          return ErrorValue.new(code: :value) unless result_node
          condition = evaluate(condition_node, origin)
          return condition if condition.is_a?(ErrorValue)
          return evaluate(result_node, origin) if Functions.truthy?(condition)
        end
        return ErrorValue.new(code: :na)
      end
      if name == "INDIRECT"
        source = evaluate(node.children[0], origin)
        return source if source.is_a?(ErrorValue)
        ast = Formula.parse("=#{Functions.text(source)}", origin: origin)
        return evaluate(ast, origin)
      end
      if name == "OFFSET"
        return evaluate_offset(node, origin)
      end

      args = node.children.map { |child| function_argument(child, name, origin) }
      args = [origin] if args.empty? && %w[ROW COLUMN].include?(name)
      error = args.lazy.map { |value| find_error(value) }.find(&:itself)
      return error if error && !ERROR_HANDLING_FUNCTIONS.include?(name)

      if name == "FORMULATEXT"
        return @formula_text[args.first] || ErrorValue.new(code: :na)
      end
      if name == "ISFORMULA"
        return @formulas.key?(args.first)
      end
      @functions[name].call(*args)
    end

    def function_argument(child, name, origin)
      return child.value if %i[reference qualified_reference].include?(child.type) && REFERENCE_FUNCTIONS.include?(name)
      if child.type == :range && REFERENCE_FUNCTIONS.include?(name)
        first, last = child.children.map(&:value)
        sheet = first.sheet || last.sheet || origin.sheet
        return Area.new(sheet: sheet, top: first.row, left: first.column, bottom: last.row, right: last.column)
      end
      evaluate(child, origin)
    end

    def evaluate_offset(node, origin)
      base = function_argument(node.children.fetch(0), "OFFSET", origin)
      return base if base.is_a?(ErrorValue)
      area = base.is_a?(Area) ? base : Area.new(sheet: base.sheet || origin.sheet,
                                                 top: base.row, left: base.column,
                                                 bottom: base.row, right: base.column)
      row_shift = Functions.integer!(evaluate(node.children.fetch(1), origin))
      column_shift = Functions.integer!(evaluate(node.children.fetch(2), origin))
      height = node.children[3] ? Functions.integer!(evaluate(node.children[3], origin)) : area.bottom - area.top + 1
      width = node.children[4] ? Functions.integer!(evaluate(node.children[4], origin)) : area.right - area.left + 1
      return ErrorValue.new(code: :ref) unless height.positive? && width.positive?

      shifted = Area.new(sheet: area.sheet, top: area.top + row_shift, left: area.left + column_shift,
                         bottom: area.top + row_shift + height - 1, right: area.left + column_shift + width - 1)
      return ErrorValue.new(code: :ref) if shifted.top < 1 || shifted.left < 1 || shifted.bottom > 1_048_576 || shifted.right > 16_384
      return read_cell(Reference.new(sheet: shifted.sheet, row: shifted.top, column: shifted.left)) if height == 1 && width == 1

      range_from_area(shifted, origin)
    rescue IndexError, ArgumentError, TypeError
      ErrorValue.new(code: :value)
    end

    def read_range(node, origin)
      first, last = node.children.map(&:value)
      first_sheet = first.sheet || origin.sheet
      last_sheet = last.sheet || first_sheet
      return ErrorValue.new(code: :ref) if first_sheet != last_sheet

      area = Area.new(sheet: first_sheet, top: first.row, left: first.column,
                      bottom: last.row, right: last.column)
      range_from_area(area, origin)
    end

    def range_from_area(area, origin)
      cells = area.bottom - area.top + 1
      columns = area.right - area.left + 1
      return ErrorValue.new(code: :num) if cells * columns > 1_000_000

      values = Array.new(cells) { Array.new(columns) }
      @inputs.each do |reference, input|
        next unless area.include?(reference)
        next if @formulas.key?(reference)

        values[reference.row - area.top][reference.column - area.left] = input
      end
      if @source&.respond_to?(:each_in)
        @source.each_in(area) do |reference, value|
          next unless reference.is_a?(Reference) && area.include?(reference)
          next if @inputs.key?(reference)

          values[reference.row - area.top][reference.column - area.left] = value
        end
      elsif @source&.respond_to?(:value_at)
        area.top.upto(area.bottom) do |row|
          area.left.upto(area.right) do |column|
            reference = Reference.new(sheet: area.sheet, row: row, column: column)
            next if @inputs.key?(reference)

            values[row - area.top][column - area.left] = @source.value_at(reference)
          end
        end
      end
      @formulas.each_key do |reference|
        next unless area.include?(reference)

        values[reference.row - area.top][reference.column - area.left] = @values[reference]
      end
      @spill_values.each do |reference, value|
        values[reference.row - area.top][reference.column - area.left] = value if area.include?(reference)
      end
      ArrayValue.new(rows: values)
    end

    def find_error(value)
      case value
      when ErrorValue then value
      when ArrayValue then value.rows.flatten.find { |cell| cell.is_a?(ErrorValue) }
      when Array then value.flatten.find { |cell| cell.is_a?(ErrorValue) }
      end
    end

    def read_name(name, origin)
      value = @names[normalize_name(name)]
      return ErrorValue.new(code: :name) unless value
      return read_cell(value) if value.is_a?(Reference)
      return value unless value.is_a?(Area)

      first = Reference.new(sheet: value.sheet || origin.sheet, row: value.top, column: value.left)
      last = Reference.new(sheet: value.sheet || origin.sheet, row: value.bottom, column: value.right)
      read_range(Node.new(type: :range, children: [Node.new(type: :reference, value: first), Node.new(type: :reference, value: last)]), origin)
    end

    def read_cell(reference)
      return ErrorValue.new(code: :cycle) if @evaluating.include?(reference)

      reference = reference.with(sheet: reference.sheet) if reference.sheet.nil?
      return @spill_values[reference] if @spill_values.key?(reference)
      return @values[reference] if @values.key?(reference)

      source_value(reference)
    end

    def source_value(reference)
      if @source.respond_to?(:value_at)
        @source.value_at(reference)
      elsif @source.is_a?(Hash)
        @source.fetch(reference) { @source[[reference.sheet, reference.row, reference.column]] }
      end
    rescue KeyError
      nil
    end

    def evaluate_binary_scalar(operator, left, right)
      case operator
      when "+" then Functions.number!(left) + Functions.number!(right)
      when "-" then Functions.number!(left) - Functions.number!(right)
      when "*" then Functions.number!(left) * Functions.number!(right)
      when "/"
        denominator = Functions.number!(right)
        denominator.zero? ? ErrorValue.new(code: :div0) : Functions.number!(left).to_f / denominator
      when "^" then Functions.number!(left)**Functions.number!(right)
      when "&" then Functions.text(left) + Functions.text(right)
      when "=" then compare(left, right).zero?
      when "<>" then !compare(left, right).zero?
      when "<" then compare(left, right).negative?
      when ">" then compare(left, right).positive?
      when "<=" then !compare(left, right).positive?
      when ">=" then !compare(left, right).negative?
      else ErrorValue.new(code: :value)
      end
    end

    def binary(operator, left, right)
      if left.is_a?(ArrayValue) || right.is_a?(ArrayValue)
        left_matrix = matrix(left); right_matrix = matrix(right)
        height = [left_matrix.length, right_matrix.length].max
        width = [left_matrix.first.length, right_matrix.first.length].max
        return ErrorValue.new(code: :value) unless [height, 1].include?(left_matrix.length) && [height, 1].include?(right_matrix.length) &&
                                                    [width, 1].include?(left_matrix.first.length) && [width, 1].include?(right_matrix.first.length)
        return ArrayValue.new(rows: Array.new(height) do |row|
          Array.new(width) do |column|
            a = left_matrix[left_matrix.length == 1 ? 0 : row][left_matrix.first.length == 1 ? 0 : column]
            b = right_matrix[right_matrix.length == 1 ? 0 : row][right_matrix.first.length == 1 ? 0 : column]
            result = evaluate_binary_scalar(operator, a, b)
            result
          end
        end)
      end
      evaluate_binary_scalar(operator, left, right)
    end

    def unary(operator, value)
      number = Functions.number!(value)
      operator == "-" ? -number : number
    end

    def compare(left, right)
      if left.is_a?(Numeric) && right.is_a?(Numeric)
        left <=> right
      elsif left.is_a?(Date) && right.is_a?(Date)
        left <=> right
      else
        Functions.text(left).downcase <=> Functions.text(right).downcase
      end
    end

    def matrix(value) = value.is_a?(ArrayValue) ? value.rows : [[value]]

    def map_array(value)
      ArrayValue.new(rows: value.rows.map { |row| row.map { |cell| yield cell } })
    end

    def store_result(reference, result)
      unless result.is_a?(ArrayValue)
        store_value(reference, result)
        return result
      end

      height = result.height
      width = result.width
      spill = {}
      result.rows.each_with_index do |row, row_offset|
        row.each_with_index do |value, column_offset|
          next if row_offset.zero? && column_offset.zero?

          target = Reference.new(sheet: reference.sheet, row: reference.row + row_offset,
                                 column: reference.column + column_offset)
          if target.row > 1_048_576 || target.column > 16_384 || occupied?(target)
            store_value(reference, ErrorValue.new(code: :spill))
            return @values[reference]
          end
          spill[target] = value
        end
      end
      store_value(reference, result[0, 0])
      @spill_refs[reference] = spill.keys.to_set
      spill.each do |target, value|
        @spill_values[target] = value
        @spill_parents[target] = reference
      end
      @values[reference]
    end

    def clear_spill(reference)
      @spill_refs.delete(reference)&.each do |spill_ref|
        @spill_values.delete(spill_ref)
        @spill_parents.delete(spill_ref)
      end
    end

    def occupied?(reference)
      @inputs.key?(reference) || @spill_parents.key?(reference) || !source_value(reference).nil?
    end

    def store_value(reference, value)
      @values[reference] = value
    end

    def value_without_recalculation(reference)
      return @spill_values[reference] if @spill_values.key?(reference)
      return @values[reference] if @values.key?(reference)

      source_value(reference)
    end

    def iterate_cycle(cycle)
      cycle.each { |reference| @values[reference] = 0 unless @values.key?(reference) }
      converged = false
      @max_iterations.times do
        previous = cycle.to_h { |reference| [reference, @values[reference]] }
        cycle.each { |reference| store_result(reference, evaluate(@formulas.fetch(reference), reference)) }
        converged = cycle.all? do |reference|
          old = previous[reference]; current = @values[reference]
          old.is_a?(Numeric) && current.is_a?(Numeric) ? (old - current).abs <= @epsilon : old == current
        end
        break if converged
      end
      cycle.each { |reference| store_value(reference, ErrorValue.new(code: :cycle)) } unless converged
    end

    def adjust_cells(type, sheet, at, count)
      operation = Adjustment.new(type: type, sheet: sheet, at: at, count: count)
      moved_inputs = {}
      moved_formula_text = {}
      @inputs.each do |reference, input|
        moved_reference = move_cell(reference, operation)
        next unless moved_reference

        moved_inputs[moved_reference] = input
        if @formulas.key?(reference)
          ast = Formula.adjust(@formulas.fetch(reference), operation)
          moved_formula_text[moved_reference] = Formula.render(ast, origin: moved_reference)
        end
      end
      @inputs = moved_inputs
      @formula_text = moved_formula_text
      @formulas = moved_formula_text.to_h { |reference, text| [reference, Formula.parse(text, origin: reference)] }
      @dynamic_formulas = @formulas.filter_map { |reference, ast| reference if has_dynamic_indirect?(ast) }.to_set
      @volatile_formulas = @formulas.filter_map { |reference, ast| reference if volatile_formula?(ast) }.to_set
      @values = @inputs.reject { |reference, _| @formulas.key?(reference) }
      @previous_values = {}
      @spill_values.clear
      @spill_refs.clear
      @spill_parents.clear
      @cycles.clear
      rebuild_formula_graph
      @dirty = @inputs.keys.to_set
      @inputs.keys.each { |reference| mark_dirty(reference) }
      self
    end

    def rebuild_formula_graph
      @precedents.clear
      @dependents.clear
      @range_dependents.clear
      @formulas.each { |reference, ast| add_formula_edges(reference, ast) }
    end

    def move_cell(reference, operation)
      return reference unless operation.sheet.nil? || reference.sheet == operation.sheet

      axis = operation.type.to_s.end_with?("rows") ? :row : :column
      coordinate = reference.public_send(axis)
      if operation.type.to_s.start_with?("insert")
        coordinate += operation.count if coordinate >= operation.at
      elsif coordinate >= operation.at && coordinate < operation.at + operation.count
        return nil
      elsif coordinate >= operation.at + operation.count
        coordinate -= operation.count
      end
      reference.with(axis => coordinate)
    end

    def normalize_name(name) = name.to_s.downcase

    def has_dynamic_indirect?(ast)
      found = false
      Formula.visit(ast) { |node| found ||= node.type == :call && node.value == "INDIRECT" && node.children.first&.type != :literal }
      found
    end

    def volatile_formula?(ast)
      found = false
      Formula.visit(ast) do |node|
        next unless node.type == :call

        entry = @functions[node.value]
        found ||= entry&.volatile || ITERATION_FUNCTIONS.include?(node.value)
      end
      found
    end

    def dynamic_precedents(ast, origin)
      references = []
      Formula.visit(ast) do |node|
        next unless node.type == :call

        if node.value == "INDIRECT" && node.children.first&.type == :literal && node.children.first.value.is_a?(String)
          begin
            references.concat(Formula.references(Formula.parse("=#{node.children.first.value}", origin: origin)))
          rescue ParseError
            nil
          end
        elsif node.value == "OFFSET" && node.children.first
          next if node.children.length < 3

          base_node = node.children.first
          base = if base_node.type == :reference
                   base_node.value
                 elsif base_node.type == :range
                   first, last = base_node.children.map(&:value)
                   Area.new(sheet: first.sheet || last.sheet || origin.sheet,
                            top: first.row, left: first.column, bottom: last.row, right: last.column)
                 end
          next unless base
          next unless node.children[1..2].all? { |arg| arg&.type == :literal && arg.value.is_a?(Numeric) }

          row_delta, column_delta = node.children[1..2].map { |arg| arg.value.to_i }
          top = (base.is_a?(Area) ? base.top : base.row) + row_delta
          left = (base.is_a?(Area) ? base.left : base.column) + column_delta
          height = node.children[3]&.value || (base.is_a?(Area) ? base.bottom - base.top + 1 : 1)
          width = node.children[4]&.value || (base.is_a?(Area) ? base.right - base.left + 1 : 1)
          if [height, width].all? { |size| size.is_a?(Numeric) && size.positive? }
            references << if height == 1 && width == 1
                            Reference.new(sheet: base.is_a?(Area) ? base.sheet : (base.sheet || origin.sheet), row: top, column: left)
                          else
                            Area.new(sheet: base.is_a?(Area) ? base.sheet : (base.sheet || origin.sheet), top: top, left: left,
                                     bottom: top + height.to_i - 1, right: left + width.to_i - 1)
                          end
          end
        end
      end
      references
    end

    def name_precedents(ast, origin)
      references = []
      Formula.visit(ast) do |node|
        next unless node.type == :name

        area = @names[normalize_name(node.value)]
        case area
        when Reference
          references << (area.sheet.nil? ? area.with(sheet: origin.sheet) : area)
        when Area
          references << (area.sheet.nil? ? area.with(sheet: origin.sheet) : area)
        end
      end
      references
    end

    def sort_key(reference) = [reference.sheet.to_s, reference.row, reference.column]
  end
end
