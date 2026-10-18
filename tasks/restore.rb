#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require_relative '../lib/pe_snapshot/task'
exit PeSnapshot::Task.run('restore')
