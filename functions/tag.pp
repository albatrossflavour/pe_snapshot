# @summary The tag a plan acts on: the one given, else the run_id in its context.
#
# @param tag The tag passed to the plan.
# @param context The plan's optional pe_patch_context Hash.
# @return [Optional[String[1]]] The tag, or undef when there is neither.
function pe_snapshot::tag(
  Optional[String[1]] $tag,
  Optional[Hash] $context,
) >> Optional[String[1]] {
  $tag.lest || { $context.then |$c| { $c['run_id'].then |$r| { String($r) } } }
}
