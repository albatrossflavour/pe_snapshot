# frozen_string_literal: true

require_relative 'actions'

module PeSnapshot
  # Wraps an action for the task runner: JSON in on stdin, JSON out, and a
  # non-zero exit only when the whole call failed. Per-node failures are in
  # the results and exit 0, so the plan can drop those nodes and carry on.
  module Task
    module_function

    def run(action, input = $stdin.read, out = $stdout)
      params = JSON.parse(input).reject { |k, _| k.start_with?('_') }
      out.puts JSON.generate(Actions.call(action, params))
      0
    rescue Error => e
      out.puts JSON.generate('_error' => e.to_h)
      1
    rescue StandardError => e
      out.puts JSON.generate('_error' => Error.new('unexpected', "#{e.class}: #{e.message}").to_h)
      1
    end
  end
end
