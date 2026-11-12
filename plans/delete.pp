# @summary Deletes managed snapshots by tag or name on each target.
#
# Deleting a snapshot that is already gone succeeds, so a retry is safe. Only
# snapshots this module created are ever touched.
#
# @param targets The nodes whose snapshots to delete.
# @param tag Delete snapshots with this tag. Defaults to the run_id in pe_patch_context.
# @param snapshot_name Delete the snapshot with this name.
# @param pe_patch_context Optional calling context. Its run_id is the tag when tag isn't given.
# @param credentials Added to the proxy's credentials files. Leave empty to use only those. Never stored in the orchestrator's job record.
# @param marker Remove the snapshot from each target's marker file.
# @return [ResultSet] Each ok value has deleted, the names removed, and pe_patch_report, a short summary for a caller that reports per node.
plan pe_snapshot::delete(
  TargetSpec $targets,
  Optional[String[1]] $tag = undef,
  Optional[String[1]] $snapshot_name = undef,
  Optional[Hash] $pe_patch_context = undef,
  Sensitive[Hash] $credentials = Sensitive({}),
  Boolean $marker = true,
) {
  $_tag = pe_snapshot::tag($tag, $pe_patch_context)
  if $_tag =~ Undef and $snapshot_name =~ Undef {
    fail_plan('pe_snapshot::delete needs a tag, a snapshot_name, or a pe_patch_context with a run_id', 'pe_snapshot/missing_parameter')
  }

  $params = { 'tag' => $_tag, 'name' => $snapshot_name }.filter |$k, $v| { $v =~ NotUndef }
  $values = run_plan('pe_snapshot::dispatch', 'targets' => $targets, 'action' => 'delete', 'params' => $params, 'credentials' => $credentials)

  $done = $values.filter |$c, $v| { !('_error' in $v) }.keys
  if $marker and !$done.empty {
    run_task('pe_snapshot::marker', $done, $params + { 'action' => 'remove', '_catch_errors' => true })
  }

  return(ResultSet.new(get_targets($targets).map |$t| {
    $v = $values[$t.name]
    if '_error' in $v {
      Result.new($t, $v)
    } else {
      Result.new($t, $v + { 'pe_patch_report' => { 'deleted' => $v['deleted'] } })
    }
  }))
}
