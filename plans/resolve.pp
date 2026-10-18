# @summary Groups targets by the proxy and endpoint that can snapshot them, from the pe_snapshot fact in PuppetDB.
#
# @api private
#
# @param targets The nodes to map.
# @return [Hash] groups: an Array of {proxy, endpoint, provider, vms}, and
#   unmapped: a Hash of certname to an _error value for nodes with no usable mapping.
plan pe_snapshot::resolve(
  TargetSpec $targets,
) {
  $names = get_targets($targets).map |$t| { $t.name }
  $rows = puppetdb_query("facts[certname, value] { name = 'pe_snapshot' and certname in ${stdlib::to_json($names)} }")
  $fact = $rows.reduce({}) |$m, $r| { $m + { $r['certname'] => $r['value'] } }

  $split = $names.reduce({ 'groups' => {}, 'unmapped' => {} }) |$acc, $n| {
    $f = $fact[$n]
    if $f =~ Undef or $f['mapped'] != true {
      $err = {
        'kind'    => 'pe_snapshot/unmapped',
        'msg'     => "${n} has no complete pe_snapshot mapping (provider, proxy, endpoint, vm_id). Declare the pe_snapshot class and set them in Hiera.",
        'details' => { 'fact' => $f },
      }
      $acc + { 'unmapped' => $acc['unmapped'] + { $n => { '_error' => $err } } }
    } else {
      $key = "${f['proxy']} ${f['endpoint']}"
      $g = $acc['groups'][$key].lest || { { 'proxy' => $f['proxy'], 'endpoint' => $f['endpoint'], 'provider' => $f['provider'], 'vms' => [] } }
      $acc + { 'groups' => $acc['groups'] + { $key => $g + { 'vms' => $g['vms'] + [{ 'certname' => $n, 'vm_id' => $f['vm_id'] }] } } }
    }
  }
  return({ 'groups' => $split['groups'].values, 'unmapped' => $split['unmapped'] })
}
