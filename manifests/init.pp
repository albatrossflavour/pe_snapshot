# @summary Maps this node to the hypervisor endpoint that can snapshot it.
#
# Declare on every node that can be snapshotted. Each value comes from Hiera
# first and is detected from facts second, so it can be set per node, location
# or network zone. The result is written where the pe_snapshot fact reads it,
# and the plans find the proxy for a node through that fact.
#
# @param provider
#   Provider name. Detected from cloud metadata facts, then from the virtual
#   fact through virtual_map.
# @param proxy
#   Certname of the node that talks to the hypervisor API for this node. It
#   needs pe_snapshot::proxy with a matching endpoint.
# @param endpoint
#   Name of the endpoint on the proxy, or a list of them. Use a list where the
#   VM can move between hosts or clusters that have separate APIs (standalone
#   ESXi, libvirt hosts, more than one vCenter). The VM is looked up on each
#   and must be found on exactly one. Don't list the same cluster twice.
# @param vm_id
#   The provider's identity for this VM. Detected per provider: the SMBIOS
#   uuid for proxmox, vsphere and libvirt, zone/name for gce, the instance id
#   for aws, the resource id for azure.
# @param restorable
#   Whether pe_snapshot::restore may roll this node back. Defaults to false on
#   PE infrastructure (any node with the pe_server_version fact), because
#   rolling back the primary or a compiler revives revoked certificates and
#   old secrets, and loses everything the CA and PuppetDB did since.
# @param virtual_map
#   Maps values of the virtual fact to a provider. kvm can't tell Proxmox from
#   plain libvirt, so set provider in Hiera where the default is wrong.
#
# @example Hiera for a site whose VMs are on one Proxmox cluster
#   pe_snapshot::proxy: puppet.lab.example.com
#   pe_snapshot::endpoint: lab_pve
class pe_snapshot (
  Optional[Pattern[/\A[a-z0-9_]+\z/]] $provider = undef,
  Optional[String[1]] $proxy = undef,
  Optional[Variant[Pattern[/\A[a-z0-9_]+\z/], Array[Pattern[/\A[a-z0-9_]+\z/], 1]]] $endpoint = undef,
  Optional[String[1]] $vm_id = undef,
  Hash[String[1], Pattern[/\A[a-z0-9_]+\z/]] $virtual_map = {},
  Boolean $restorable = $facts['pe_server_version'] =~ Undef,
) {
  # Facter can report physical for a guest: Rocky 9 and 10 images without
  # virt-what, and Windows on Proxmox. Its hypervisors fact (Windows: kvm) or
  # the DMI manufacturer (Rocky: QEMU) still names the hypervisor.
  $virtual = if $facts['virtual'] == 'physical' {
    $from_hypervisors = ($facts['hypervisors'].lest || { {} }).keys.filter |$h| { $h in ['kvm', 'vmware'] }
    if !$from_hypervisors.empty {
      $from_hypervisors[0]
    } else {
      $facts.dig('dmi', 'manufacturer') ? {
        'QEMU'         => 'kvm',
        'VMware, Inc.' => 'vmware',
        default        => 'physical',
      }
    }
  } else {
    $facts['virtual']
  }
  $detected_provider = if $facts['ec2_metadata'] {
    'aws'
  } elsif $facts['az_metadata'] {
    'azure'
  } else {
    $virtual_map[$virtual]
  }
  $_provider = $provider.lest || { $detected_provider }

  $detected_vm_id = $_provider ? {
    'gce'   => $facts.dig('gce', 'instance', 'name').then |$n| {
      "${regsubst($facts.dig('gce', 'instance', 'zone'), '^.*/', '')}/${n}"
    },
    'aws'   => $facts.dig('ec2_metadata', 'instance-id'),
    'azure' => $facts.dig('az_metadata', 'compute', 'resourceId'),
    default => $facts.dig('dmi', 'product', 'uuid').then |$u| { downcase($u) },
  }
  $_vm_id = $vm_id.lest || { $detected_vm_id }

  $dir = $facts['os']['family'] ? {
    'windows' => 'C:/ProgramData/PuppetLabs/pe_snapshot',
    default   => '/etc/puppetlabs/pe_snapshot',
  }
  $config = {
    'provider'   => $_provider,
    'proxy'      => $proxy,
    'endpoint'   => $endpoint,
    'vm_id'      => $_vm_id,
    'restorable' => $restorable,
    'mapped'     => [$_provider, $proxy, $endpoint, $_vm_id].all |$v| { $v =~ NotUndef },
  }

  file { $dir:
    ensure => directory,
  }
  file { "${dir}/target.json":
    ensure  => file,
    content => stdlib::to_json($config),
  }
}
