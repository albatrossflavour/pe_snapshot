# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'
require 'openssl'
require 'rbconfig'
require 'uri'

# Shared code for the pe_snapshot tasks, facts and sweep. Stdlib only, because
# it runs under the agent's Ruby on whatever node is the proxy.
module PeSnapshot
  PREFIX = 'pes-'
  META_TAG = 'pe_snapshot:'
  WINDOWS = RbConfig::CONFIG['host_os'].match?(%r{mswin|mingw})
  CONFIG_DIR = WINDOWS ? 'C:/ProgramData/PuppetLabs/pe_snapshot' : '/etc/puppetlabs/pe_snapshot'
  ENDPOINT_DIR = File.join(CONFIG_DIR, 'endpoints')
  # Written by something other than Puppet (Vault Agent, CyberArk, a script),
  # so Puppet creates it but never purges it. Fixed, so a caller can't point
  # a task at another file.
  EXTERNAL_CREDENTIALS_DIR = File.join(CONFIG_DIR, 'credentials.d')
  NAME_PATTERN = %r{\A[a-z0-9_]+\z}

  # An error a task reports as `_error`, with a kind callers can match on.
  class Error < StandardError
    attr_reader :kind, :details

    def initialize(kind, msg, details = {})
      super(msg)
      @kind = "pe_snapshot/#{kind}"
      @details = details
    end

    def to_h
      { 'kind' => kind, 'msg' => message, 'details' => details }
    end
  end

  module_function

  # Short enough and plain enough for every provider. Proxmox is the tightest:
  # 40 characters of [A-Za-z0-9_-], starting with a letter.
  def snapshot_name(tag, time)
    "#{PREFIX}#{Digest::SHA256.hexdigest(tag)[0, 8]}-#{time.to_i}"
  end

  def encode_meta(meta)
    META_TAG + JSON.generate(meta)
  end

  # Returns nil for anything this module did not write, so hand-made
  # snapshots are never treated as managed.
  def decode_meta(description)
    text = description.to_s
    idx = text.index(META_TAG)
    return nil unless idx

    meta = JSON.parse(text[(idx + META_TAG.length)..].strip)
    (meta.is_a?(Hash) && meta['pe_snapshot']) ? meta : nil
  rescue JSON::ParserError
    nil
  end

  def managed?(name, meta)
    name.to_s.start_with?(PREFIX) && !meta.nil?
  end

  def age_bucket(age_seconds)
    case age_seconds
    when ...3600 then 'lt_1h'
    when ...86_400 then '1h_24h'
    when ...604_800 then '1d_7d'
    else 'gt_7d'
    end
  end

  # expires of 0 means "until deleted".
  def state(meta, now)
    expires = meta['expires'].to_i
    (expires.positive? && now.to_i >= expires) ? 'expired' : 'active'
  end

  # Providers use this to pick the VM matching an id. More than one match is
  # refused: clones can keep their source's BIOS uuid (vCenter asks, and
  # people answer "keep"), and guessing could restore the wrong VM.
  def one_vm(matches, vm_id, endpoint_name)
    raise Error.new('vm_not_found', "No VM matches '#{vm_id}' on endpoint #{endpoint_name}", 'vm_id' => vm_id) if matches.empty?

    if matches.size > 1
      raise Error.new('ambiguous_vm', "#{matches.size} VMs match '#{vm_id}' on endpoint #{endpoint_name}, probably a clone that kept its uuid. Set pe_snapshot::vm_id for this node.",
                      'vm_id' => vm_id, 'matches' => matches)
    end

    matches.first
  end

  # The provider name comes from config or task input, so it is checked
  # against a plain pattern before it becomes a file path.
  def provider_class(name)
    raise Error.new('unknown_provider', "Invalid provider name '#{name}'") unless name.to_s.match?(NAME_PATTERN)

    begin
      require_relative File.join('providers', name)
    rescue LoadError
      raise Error.new('unknown_provider', "No provider named '#{name}'")
    end
    Providers.const_get(name.split('_').map(&:capitalize).join)
  end

  # Reads an endpoint's config and its credentials, from up to three places:
  # the file Puppet writes, the file an external agent writes, and the
  # caller's Sensitive parameter. A key supplied twice is an error, because
  # silently preferring one source hides a misconfiguration.
  def load_endpoint(name, extra_credentials = nil, dir = ENDPOINT_DIR, external_dir = EXTERNAL_CREDENTIALS_DIR)
    raise Error.new('bad_endpoint', "Invalid endpoint name '#{name}'") unless name.to_s.match?(NAME_PATTERN)

    config_file = File.join(dir, "#{name}.json")
    raise Error.new('unknown_endpoint', "Endpoint '#{name}' is not configured on this proxy", 'path' => config_file) unless File.file?(config_file)

    config = JSON.parse(File.read(config_file))
    sources = {
      'the Puppet-managed file' => read_secret(File.join(dir, "#{name}.creds.json")),
      'the external file' => read_secret(File.join(external_dir, "#{name}.json")),
      'the caller' => extra_credentials || {},
    }
    merged = {}
    sources.each do |source, creds|
      clash = merged.keys & creds.keys
      raise Error.new('credentials_conflict', "Credential keys supplied twice for endpoint '#{name}', again by #{source}: #{clash.join(', ')}") unless clash.empty?

      merged.merge!(creds)
    end
    config.merge('credentials' => merged)
  end

  # Nothing from the file's content goes into an error: the message ends up
  # in the proxy fact, so in PuppetDB, and a JSON parser error quotes the
  # text around the fault, which can be the secret.
  def read_secret(path)
    return {} unless File.file?(path)

    unless WINDOWS
      stat = File.stat(path)
      raise Error.new('insecure_credentials', "#{path} must be owned by root", 'path' => path) unless stat.uid.zero?
      raise Error.new('insecure_credentials', "#{path} must not be readable by group or others", 'path' => path) unless stat.mode.nobits?(0o077)
    end
    creds = JSON.parse(File.read(path))
    raise Error.new('unreadable_credentials', "#{path} does not hold a JSON object", 'path' => path) unless creds.is_a?(Hash)

    creds
  rescue JSON::ParserError
    raise Error.new('unreadable_credentials', "#{path} is not valid JSON", 'path' => path)
  end

  def provider_for(endpoint)
    provider_class(endpoint['provider']).new(endpoint)
  end

  def endpoint_names(dir = ENDPOINT_DIR)
    Dir.glob(File.join(dir, '*.json')).reject { |f| f.end_with?('.creds.json') }.map { |f| File.basename(f, '.json') }.sort
  end

  # Runs the block for each item on at most `limit` threads. Results come back
  # in input order.
  def each_concurrently(items, limit)
    queue = Queue.new
    items.each_with_index { |item, i| queue << [item, i] }
    results = Array.new(items.size)
    workers = Array.new(limit.to_i.clamp(1, [items.size, 1].max)) do
      Thread.new do
        loop do
          item, i = queue.pop(true)
          results[i] = yield(item)
        rescue ThreadError
          break
        end
      end
    end
    workers.each(&:join)
    results
  end

  # A small JSON client over Net::HTTP.
  class HTTP
    def initialize(base_url, headers: {}, verify_tls: true, ca_file: nil, timeout: 30)
      @base = URI(base_url.to_s.chomp('/'))
      @headers = headers
      @verify_tls = verify_tls
      @ca_file = ca_file
      @timeout = timeout
    end

    def get(path)
      request(Net::HTTP::Get, path)
    end

    def post(path, body = {})
      request(Net::HTTP::Post, path, body)
    end

    # OAuth token endpoints want a form, not JSON.
    def post_form(path, fields)
      request(Net::HTTP::Post, path, URI.encode_www_form(fields), 'application/x-www-form-urlencoded')
    end

    def delete(path)
      request(Net::HTTP::Delete, path)
    end

    def request(klass, path, body = nil, content_type = 'application/json')
      uri = URI("#{@base}#{path}")
      req = klass.new(uri)
      @headers.each { |k, v| req[k] = v }
      if body
        req['Content-Type'] = content_type
        req.body = body.is_a?(String) ? body : JSON.generate(body)
      end
      res = Net::HTTP.start(uri.host, uri.port, nil, use_ssl: uri.scheme == 'https', verify_mode: @verify_tls ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
                                                     ca_file: @ca_file, open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.request(req)
      end
      raise Error.new('api_error', "#{klass::METHOD} #{uri.path} returned HTTP #{res.code}: #{res.body.to_s[0, 500]}", 'status' => res.code.to_i, 'path' => uri.path) unless res.is_a?(Net::HTTPSuccess)

      res.body.to_s.empty? ? {} : JSON.parse(res.body)
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error.new('api_unreachable', "#{uri}: #{e.class}: #{e.message}")
    end
  end

  # Provider classes, one file each under providers/, loaded by provider_class.
  module Providers; end
end
