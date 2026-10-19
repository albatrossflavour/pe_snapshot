# @summary Configures a node to talk to hypervisor APIs for pe_snapshot, and sweeps expired snapshots.
#
# The plans run their tasks on this node. Each endpoint gets a config file and
# a root-only credentials file under /etc/puppetlabs/pe_snapshot/endpoints.
# The pe_snapshot_proxy fact lists every managed snapshot on those endpoints,
# and when it shows expired ones this class deletes exactly those. A run only
# reports a change when something was deleted.
#
# Linux only.
#
# @param endpoints
#   The hypervisor or cloud endpoints this proxy can reach. Provider-specific
#   settings go in options and are merged into the endpoint's config.
# @param credentials
#   Credentials per endpoint name. Each value is a Hash, a JSON string, or a
#   Deferred that returns one of those (a Vault or KMS lookup), which resolves
#   on this node at run time and so never enters the catalog. Converted to
#   Sensitive by the module's lookup_options.
# @param default_retention_hours
#   Expiry for a snapshot created without retention_hours.
# @param max_retention_hours
#   The longest retention a caller may ask for. Longer requests are refused.
# @param allow_no_expiry
#   Whether retention_hours 0, meaning no expiry, is accepted.
# @param sweep
#   Whether agent runs delete expired snapshots.
#
# @example Hiera for one Proxmox cluster
#   pe_snapshot::proxy::endpoints:
#     - name: lab_pve
#       provider: proxmox
#       url: https://pve1.example.com:8006
#   pe_snapshot::proxy::credentials:
#     lab_pve: ENC[PKCS7,...]
class pe_snapshot::proxy (
  Array[Struct[{
    name                 => Pattern[/\A[a-z0-9_]+\z/],
    provider             => Pattern[/\A[a-z0-9_]+\z/],
    Optional[url]        => String[1],
    Optional[verify_tls] => Boolean,
    Optional[ca_file]    => Stdlib::Absolutepath,
    Optional[options]    => Hash[String[1], Data],
  }]] $endpoints = [],
  Variant[Sensitive[Hash], Hash] $credentials = {},
  Integer[1] $default_retention_hours = 24,
  Integer[1] $max_retention_hours = 168,
  Boolean $allow_no_expiry = false,
  Boolean $sweep = true,
) {
  if $default_retention_hours > $max_retention_hours {
    fail("pe_snapshot::proxy: default_retention_hours ${default_retention_hours} is over max_retention_hours ${max_retention_hours}")
  }

  $dir = '/etc/puppetlabs/pe_snapshot'
  $endpoint_dir = "${dir}/endpoints"
  $_credentials = $credentials ? {
    Sensitive => $credentials.unwrap,
    default   => $credentials,
  }

  # pe_snapshot owns the config directory, and a proxy is a node like any other.
  contain pe_snapshot

  # Purged so an endpoint removed from Hiera loses its credentials too.
  file { $endpoint_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0700',
    recurse => true,
    purge   => true,
    force   => true,
    require => File[$dir],
  }

  # For credentials written by something other than Puppet (Vault Agent,
  # CyberArk, a script), as <endpoint>.json, root-owned and 0600. Puppet owns
  # the directory but never its contents, so nothing here purges them.
  file { "${dir}/credentials.d":
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0700',
    require => File[$dir],
  }

  $endpoints.each |$ep| {
    $config = ($ep - 'options') + $ep.get('options', {}) + {
      'default_retention_hours' => $default_retention_hours,
      'max_retention_hours'     => $max_retention_hours,
      'allow_no_expiry'         => $allow_no_expiry,
    }
    file { "${endpoint_dir}/${ep['name']}.json":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      backup  => false,
      content => stdlib::to_json_pretty($config),
    }

    $creds = $_credentials[$ep['name']]
    unless $creds =~ Undef {
      $creds_content = if $creds =~ Deferred {
        Deferred('pe_snapshot::creds_json', [$creds])
      } else {
        pe_snapshot::creds_json($creds)
      }
      file { "${endpoint_dir}/${ep['name']}.creds.json":
        ensure    => file,
        owner     => 'root',
        group     => 'root',
        mode      => '0600',
        show_diff => false,
        backup    => false,
        content   => $creds_content,
      }
    }
  }

  $listed = $facts.dig('pe_snapshot_proxy', 'snapshots').lest || { [] }
  if $sweep {
    # The fact's values come from snapshot metadata on the hypervisor, so
    # anything that doesn't look like ours is left out of the command line.
    $expired = $listed.filter |$s| {
      $s['state'] == 'expired' and $s['name'] =~ /\Apes-[0-9a-f]{8}-[0-9]+\z/ and String($s['vm_id']) =~ /\A[A-Za-z0-9._:\/-]+\z/
    }
    $endpoints.each |$ep| {
      $mine = $expired.filter |$s| { $s['endpoint'] == $ep['name'] }
      unless $mine.empty {
        $pairs = $mine.map |$s| { "${s['vm_id']}=${s['name']}" }.join(' ')
        # Declared only when the fact lists expired snapshots, so a clean run declares nothing.
        # lint:ignore:exec_idempotency
        exec { "pe_snapshot sweep ${ep['name']}":
          command   => "/opt/puppetlabs/puppet/bin/ruby -I/opt/puppetlabs/puppet/cache/lib -rpe_snapshot/sweep -e 'exit PeSnapshot::Sweep.run(ARGV)' ${ep['name']} ${pairs}",
          logoutput => true,
          require   => File["${endpoint_dir}/${ep['name']}.json"],
        }
        # lint:endignore
      }
    }
  }
}
