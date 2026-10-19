# @summary Lists the managed snapshots on each target, asking the hypervisor, not the facts.
#
# @param targets The nodes to list.
# @param tag Only list snapshots with this tag.
# @param credentials Added to the proxy's credentials files. Leave empty to use only those. Never stored in the orchestrator's job record.
# @return [ResultSet] Each ok value has snapshots: name, tag, created, expires, state, age_bucket.
plan pe_snapshot::list(
  TargetSpec $targets,
  Optional[String[1]] $tag = undef,
  Sensitive[Hash] $credentials = Sensitive({}),
) {
  $params = { 'tag' => $tag }.filter |$k, $v| { $v =~ NotUndef }
  $values = run_plan('pe_snapshot::dispatch', 'targets' => $targets, 'action' => 'list', 'params' => $params, 'credentials' => $credentials)
  return(ResultSet.new(get_targets($targets).map |$t| { Result.new($t, $values[$t.name]) }))
}
