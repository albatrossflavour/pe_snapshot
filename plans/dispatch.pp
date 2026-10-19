# @summary Runs a pe_snapshot task on each proxy for its share of the targets and returns one value per target.
#
# @api private
#
# @param targets The nodes to act on.
# @param action The task to run on each proxy.
# @param params Task parameters shared by every proxy.
# @param credentials Merged into each task's credentials, unwrapped only here. Empty means none.
# @return [Hash] certname to the task's value for that node, or an _error value.
plan pe_snapshot::dispatch(
  TargetSpec $targets,
  Enum['create', 'delete', 'list', 'restore'] $action,
  Hash $params = {},
  Sensitive[Hash] $credentials = Sensitive({}),
) {
  $map = run_plan('pe_snapshot::resolve', 'targets' => $targets)
  # Typed exactly Sensitive, not Optional[Sensitive], in every plan: the
  # orchestrator only wraps JSON input and keeps the value out of the job
  # record for a parameter of that exact type. An empty hash means none given.
  $creds = $credentials.unwrap.empty ? {
    true    => {},
    default => { 'credentials' => $credentials.unwrap },
  }

  $values = $map['groups'].reduce($map['unmapped']) |$acc, $g| {
    $task_params = $params + $creds + {
      'provider'      => $g['provider'],
      'endpoint'      => $g['endpoint'],
      'vms'           => $g['vms'],
      '_catch_errors' => true,
    }
    $result = run_task("pe_snapshot::${action}", $g['proxy'], $task_params).first
    $acc + $g['vms'].reduce({}) |$m, $vm| {
      $c = $vm['certname']
      $v = if $result.ok {
        $result.value.dig('results', $c).lest || {
          { '_error' => { 'kind' => 'pe_snapshot/no_result', 'msg' => "Proxy ${g['proxy']} returned nothing for ${c}", 'details' => {} } }
        }
      } else {
        { '_error' => { 'kind' => $result.error.kind, 'msg' => $result.error.message, 'details' => { 'proxy' => $g['proxy'], 'endpoint' => $g['endpoint'] } } }
      }
      $m + { $c => $v }
    }
  }
  return($values)
}
