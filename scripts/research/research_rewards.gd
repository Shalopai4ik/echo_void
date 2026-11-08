extends Node
class_name ResearchRewards

## What a finished analysis gives back besides Research XP.
##
## The research desk pays XP itself. This node listens to the same
## `research_completed` and, when the subject was a research object, applies
## the kind's reward from `POICatalog` to the real ship: hull repaired through
## `ShipSystems.repair_hull()`, energy through `add_energy()`, decoys and flares
## through the devices' own `add_charges()`. It also tells the creature's ear
## how loud the study was, and reports the finding in the notification feed.
##
## Mounted next to the desk under Ship/Systems; finds everything else through
## the tree.

signal rewarded(subject_id: String, poi_kind: String, summary: String)

var _desk: Node = null
var _systems: Node = null


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	_systems = get_parent()
	if _systems != null:
		_desk = _systems.get_node_or_null("Research")
	if _desk != null and _desk.has_signal("research_completed"):
		_desk.connect("research_completed", _on_completed)


func _on_completed(subject_id: String, type_id: String, xp: int, was_new: bool, _data: Dictionary) -> void:
	var tree := get_tree()
	var field := tree.get_first_node_in_group(POIField.GROUP) as POIField
	var poi: ResearchPOI = field.poi_for_subject(subject_id) if field != null else null
	if poi == null:
		var label := _type_label(type_id)
		if was_new:
			GameFeed.notify(tree, GameFeed.INFO, "ИССЛЕДОВАНИЕ ЗАВЕРШЕНО",
				"%s: +%d Research XP." % [label, xp])
		GameFeed.sfx(tree, "research_done")
		rewarded.emit(subject_id, type_id, "")
		return
	var kind := POICatalog.kind(poi.poi_kind)
	var parts: Array[String] = []
	if was_new:
		parts = apply_reward(kind.get("reward", {}))
	var notes: Array = kind.get("notes", [])
	var note := ""
	if not notes.is_empty():
		note = str(notes[absi(hash(poi.poi_id)) % notes.size()])
	var text := "+%d Research XP." % xp
	if not parts.is_empty():
		text += " " + ", ".join(parts) + "."
	if not note.is_empty():
		text = note + " " + text
	GameFeed.notify(tree, GameFeed.INFO, "%s ИЗУЧЕН" % poi.title, text)
	GameFeed.sfx(tree, "research_done")
	var disturbance := float(kind.get("disturbance", 0.0))
	if disturbance > 0.0:
		var att := tree.get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
		if att != null:
			att.add_spike(disturbance, poi.global_position, "study")
	rewarded.emit(subject_id, poi.poi_kind, text)


## Apply a reward dictionary to the ship. Returns the human-readable parts.
func apply_reward(reward: Dictionary) -> Array[String]:
	var parts: Array[String] = []
	if _systems == null:
		return parts
	var repair := float(reward.get("repair", 0.0))
	if repair > 0.0 and _systems.has_method("repair_hull"):
		var done := float(_systems.call("repair_hull", repair))
		if done > 0.0:
			parts.append("корпус +%d%%" % roundi(done * 100.0))
	var energy := float(reward.get("energy", 0.0))
	if energy > 0.0 and _systems.has_method("add_energy"):
		var got := float(_systems.call("add_energy", energy))
		if got > 0.0:
			parts.append("энергия +%d" % roundi(got))
	var decoys := int(reward.get("decoy", 0))
	if decoys > 0:
		var launcher := _systems.get_node_or_null("DecoyLauncher")
		if launcher != null and launcher.has_method("add_charges"):
			var n := int(launcher.call("add_charges", decoys))
			if n > 0:
				parts.append("ложные цели +%d" % n)
	var flares := int(reward.get("flare", 0))
	if flares > 0:
		var light := _systems.get_node_or_null("SignalLight")
		if light != null and light.has_method("add_charges"):
			var n := int(light.call("add_charges", flares))
			if n > 0:
				parts.append("огни +%d" % n)
	return parts


func _type_label(type_id: String) -> String:
	if _desk != null and _desk.has_method("type_for"):
		var profile: Variant = _desk.get("profile")
		if profile != null and profile.has_method("type"):
			var t: Variant = profile.call("type", type_id)
			if t != null:
				return str(t.call("label"))
	return type_id
