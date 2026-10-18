# @summary Rolls one node back to a managed snapshot.
#
# Deliberately narrow: exactly one target, and the tag is required. Not meant
# as a runbook step. The snapshot is kept after the rollback, and the node's
# marker file is rolled back with the disk, so its pe_snapshot fact won't list
# the snapshot until the next create. The proxy's fact still does.
#
# @param targets The one node to restore.
# @param tag Tag of the snapshot to restore.
# @param snapshot_name Needed when more than one snapshot has the tag.
# @param start Start the VM after the rollback.
# @param credentials Added to the proxy's credentials file.
# @return [ResultSet] The ok value has name, tag and pe_patch_report.
plan pe_snapshot::restore(
  TargetSpec $targets,
  String[1] $tag,
  Optional[String[1]] $snapshot_name = undef,
  Boolean $start = true,
  Optional[Sensitive[Hash]] $credentials = undef,
) {
  $_targets = get_targets($targets)
  if $_targets.length != 1 {
    fail_plan("pe_snapshot::restore takes exactly one target, got ${_targets.length}", 'pe_snapshot/too_many_targets')
  }

  $params = { 'tag' => $tag, 'name' => $snapshot_name, 'start' => $start }.filter |$k, $v| { $v =~ NotUndef }
  $values = run_plan('pe_snapshot::dispatch', 'targets' => $_targets, 'action' => 'restore', 'params' => $params, 'credentials' => $credentials)

  $t = $_targets[0]
  $v = $values[$t.name]
  $value = if '_error' in $v { $v } else { $v + { 'pe_patch_report' => { 'restored' => $v['name'] } } }
  return(ResultSet.new([Result.new($t, $value)]))
}
