# frozen_string_literal: true

require_relative "furud/version"
require_relative "furud/types"
require_relative "furud/formula"
require_relative "furud/functions"
require_relative "furud/format"
require_relative "furud/engine"

module Furud
  module Source; end

  class Error < StandardError; end
  class ParseError < Error; end
end
