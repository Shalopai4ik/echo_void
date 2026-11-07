extends Resource
class_name ResearchUpgradeProfile

## The whole catalogue of equipment upgrades, as data.
##
## A profile carries a list of `ResearchUpgrade` entries. Adding a new upgrade
## is a new entry here - never an edit to `research_upgrade_manager.gd`.

@export_group("Upgrades")
## Every upgrade level in the catalogue, in any order. The manager indexes
## them by `upgrade_id` and `level`.
@export var upgrades: Array[ResearchUpgrade] = []

## The upgrade entry for `upgrade_id` at `level`, or null when none exists.
func find(upgrade_id: String, level: int) -> ResearchUpgrade:
	for u in upgrades:
		if u != null and u.upgrade_id == upgrade_id and u.level == level:
			return u
	return null

## The highest max_level declared for `upgrade_id`, or 0 when unknown.
func max_level_for(upgrade_id: String) -> int:
	var result := 0
	for u in upgrades:
		if u != null and u.upgrade_id == upgrade_id:
			result = max(result, u.max_level)
	return result

## The XP cost of the next level after `current_level`, or -1 when no next
## level exists.
func next_cost(upgrade_id: String, current_level: int) -> int:
	var next := find(upgrade_id, current_level + 1)
	return next.cost_xp if next != null else -1

## True when `upgrade_id` has a next level available.
func has_next(upgrade_id: String, current_level: int) -> bool:
	return find(upgrade_id, current_level + 1) != null

## All upgrade ids known to this profile.
func upgrade_ids() -> Array[String]:
	var ids: Array[String] = []
	for u in upgrades:
		if u != null and not ids.has(u.upgrade_id):
			ids.append(u.upgrade_id)
	return ids

## All entries for one upgrade path, sorted by level.
func path(upgrade_id: String) -> Array[ResearchUpgrade]:
	var out: Array[ResearchUpgrade] = []
	for u in upgrades:
		if u != null and u.upgrade_id == upgrade_id:
			out.append(u)
	out.sort_custom(func(a, b):
		return a.level < b.level)
	return out