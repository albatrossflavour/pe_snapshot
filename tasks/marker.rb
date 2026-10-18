#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

# Records or forgets a snapshot in the node's own marker file, which the
# pe_snapshot fact reads. Self-contained so it runs on any agent, Windows
# included. The proxy's fact is the authoritative list; this is the node's view.

require 'fileutils'
require 'json'
require 'rbconfig'

dir = if RbConfig::CONFIG['host_os'].match?(%r{mswin|mingw})
        'C:/ProgramData/PuppetLabs/pe_snapshot'
      else
        '/etc/puppetlabs/pe_snapshot'
      end
path = File.join(dir, 'active.json')

begin
  params = JSON.parse($stdin.read)
  entries = File.file?(path) ? Array(JSON.parse(File.read(path))) : []
  case params['action']
  when 'add'
    entry = params.slice('name', 'tag', 'created', 'expires')
    entries = entries.reject { |e| e['name'] == entry['name'] } << entry
  when 'remove'
    entries = entries.reject { |e| (params['tag'] && e['tag'] == params['tag']) || (params['name'] && e['name'] == params['name']) }
  end
  FileUtils.mkdir_p(dir)
  File.write("#{path}.tmp", JSON.generate(entries))
  File.rename("#{path}.tmp", path)
  puts JSON.generate('entries' => entries.size)
rescue StandardError => e
  puts JSON.generate('_error' => { 'kind' => 'pe_snapshot/marker_failed', 'msg' => "#{e.class}: #{e.message}", 'details' => {} })
  exit 1
end
