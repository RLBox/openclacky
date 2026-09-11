# frozen_string_literal: true

require_relative "codex_home"
require_relative "launcher"

module Clacky
  module DefaultExtensions
    module Codex
      # Runtime adapter shell. ACP authentication and session behavior are
      # added by the next implementation slice.
      class Runtime
        def initialize(**_options); end
      end
    end
  end
end
