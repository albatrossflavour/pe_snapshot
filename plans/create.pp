# @summary Snapshots each target through the proxy that serves it, with an expiry.
#
# Works on its own and as a pe_patch::runbook step (type: plan, context: true),
# where the runbook's run_id becomes the tag. Returns one Result per target. A
# node whose snapshot failed has an _error value, so a runbook step can drop it.
#
# @param targets The nodes to snapshot.
# @param tag Groups this run's snapshots for delete and restore. Defaults to pe_patch_context's run_id.
# @param pe_patch_context Passed by a pe_patch::runbook step.
# @param retention_hours Hours until the proxy's sweep deletes the snapshot. Defaults to the proxy's setting.
# @param memory Include RAM state where the provider supports it.
# @param quiesce Quiesce the guest filesystem where the provider supports it.
# @param credentials Added to the proxy's credentials file. Not usable from a runbook, which is plain data.
# @param marker Record the snapshot on each target, for the target's pe_snapshot fact.
# @return [ResultSet] Each ok value has name, tag, created, expires and pe_patch_report.
plan pe_snapshot::create(
  TargetSpec $targets,
  Optional[String[1]] $tag = undef,
  Optional[Hash] $pe_patch_context = undef,
  Optional[Integer[0]] $retention_hours = undef,
  Boolean $memory = false,
  Boolean $quiesce = false,
  Optional[Sensitive[Hash]] $credentials = undef,
  Boolean $marker = true,
) {
  $_tag = pe_snapshot::tag($tag, $pe_patch_context)
  if $_tag =~ Undef {
    fail_plan('pe_snapshot::create needs a tag, or a pe_patch_context with a run_id', 'pe_snapshot/missing_parameter')
  }

  $params = {
    'tag'     => $_tag,
    'memory'  => $memory,
    'quiesce' => $quiesce,
    'by'      => $pe_patch_context.then |$c| { "pe_patch::runbook ${c['runbook']}" }.lest || { 'pe_snapshot::create' },
  } + $retention_hours.then |$h| { { 'retention_hours' => $h } }.lest || { {} }
  $values = run_plan('pe_snapshot::dispatch', 'targets' => $targets, 'action' => 'create', 'params' => $params, 'credentials' => $credentials)

  # Proxies can differ in default retention, so markers go out per distinct snapshot.
  $marker_errors = if $marker {
    $values.filter |$c, $v| { !('_error' in $v) }.group_by |$pair| { "${pair[1]['name']} ${pair[1]['expires']}" }.reduce({}) |$acc, $kv| {
      $snap = $kv[1][0][1]
      $marked = run_task('pe_snapshot::marker', $kv[1].map |$pair| { $pair[0] }, {
        'action'        => 'add',
        'name'          => $snap['name'],
        'tag'           => $snap['tag'],
        'created'       => $snap['created'],
        'expires'       => $snap['expires'],
        '_catch_errors' => true,
      })
      $acc + $marked.error_set.reduce({}) |$m, $r| { $m + { $r.target.name => $r.error.message } }
    }
  } else {
    {}
  }

  return(ResultSet.new(get_targets($targets).map |$t| {
    $v = $values[$t.name]
    if '_error' in $v {
      Result.new($t, $v)
    } else {
      $marker_error = $marker_errors[$t.name].then |$e| { { 'marker_error' => $e } }.lest || { {} }
      Result.new($t, $v + $marker_error + { 'pe_patch_report' => { 'name' => $v['name'], 'expires' => $v['expires'] } })
    }
  }))
}
