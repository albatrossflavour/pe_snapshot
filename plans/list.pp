# @summary Lists the managed snapshots on each target, asking the hypervisor, not the facts.
#
# @param targets The nodes to list.
# @param tag Only list snapshots with this tag.
# @param credentials Added to the proxy's credentials file.
# @return [ResultSet] Each ok value has snapshots: name, tag, created, expires, state, age_bucket.
plan pe_snapshot::list(
  TargetSpec $targets,
  Optional[String[1]] $tag = undef,
  Optional[Sensitive[Hash]] $credentials = undef,
) {
  $params = { 'tag' => $tag }.filter |$k, $v| { $v =~ NotUndef }
  $values = run_plan('pe_snapshot::dispatch', 'targets' => $targets, 'action' => 'list', 'params' => $params, 'credentials' => $credentials)
  return(ResultSet.new(get_targets($targets).map |$t| { Result.new($t, $values[$t.name]) }))
}
