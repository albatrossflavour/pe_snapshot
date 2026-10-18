# frozen_string_literal: true

require 'json'

# @summary Turns endpoint credentials into the JSON written to the proxy's credentials file.
#
# Runs at compile time for plain or Sensitive values, and on the proxy agent
# when the credentials are Deferred, so a KMS lookup never puts the secret in
# the catalog. Accepts a Hash, a JSON string, or either wrapped in Sensitive,
# with Sensitive values nested at any depth.
Puppet::Functions.create_function(:'pe_snapshot::creds_json') do
  # @param creds The credentials.
  # @return [Sensitive[String]] The credentials as a JSON object.
  dispatch :convert do
    param 'Variant[Sensitive, Hash, String]', :creds
    return_type 'Sensitive[String]'
  end

  def convert(creds)
    value = unwrap(creds)
    hash = value.is_a?(String) ? JSON.parse(value) : value
    raise ArgumentError, 'pe_snapshot::creds_json: credentials must be a JSON object' unless hash.is_a?(Hash)

    Puppet::Pops::Types::PSensitiveType::Sensitive.new(JSON.generate(hash))
  rescue JSON::ParserError
    # The message from the parser can quote the secret, so it is not passed on.
    raise ArgumentError, 'pe_snapshot::creds_json: credentials string is not valid JSON'
  end

  def unwrap(value)
    case value
    when Puppet::Pops::Types::PSensitiveType::Sensitive then unwrap(value.unwrap)
    when Hash then value.transform_values { |v| unwrap(v) }
    when Array then value.map { |v| unwrap(v) }
    else value
    end
  end
end
