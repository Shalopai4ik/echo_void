class_name SectorObjective
extends RefCounted

## The sector card's data, taken from the research desk.
##
## The card in the corner of the glass used to be a painted "0 / 1". It is not
## a new mission system: it reports what the desk already knows - how many
## subjects it has seen and how many it has finished - and the goal is one
## studied object. Nothing here starts, stops or scores anything.
##
## The desk is read through its own public surface (`to_dict()`), so the card
## cannot drift from the ship: the same entries that carry XP are the entries
## that carry the progress.

## How many studied objects close the sector.
const TARGET := 1

## The three states the card can show.
enum State { IDLE, ACTIVE, DONE }


## Build the card's snapshot from the research desk. A missing desk is not an
## error: the card then shows an untouched sector.
static func build(desk: Object) -> Dictionary:
	var out := {
		"target": TARGET,
		"discovered": 0,
		"completed": 0,
		"progress": 0.0,
		"state": State.IDLE,
		"state_text": "НЕ НАЧАТО",
		"value_text": "0 / %d" % TARGET,
	}
	if desk == null or not is_instance_valid(desk):
		return out
	var data: Dictionary = {}
	if desk.has_method("to_dict"):
		var raw: Variant = desk.call("to_dict")
		if raw is Dictionary:
			data = raw as Dictionary
	var subjects: Dictionary = data.get("progress", {})
	var discovered := 0
	var completed := 0
	for subject_id in subjects:
		var entry: Variant = subjects[subject_id]
		if not entry is Dictionary:
			continue
		var record := entry as Dictionary
		discovered += 1
		if bool(record.get("completed", false)):
			completed += 1
	out["discovered"] = discovered
	out["completed"] = completed
	var done := mini(completed, TARGET)
	out["progress"] = float(done) / float(maxi(TARGET, 1))
	out["value_text"] = "%d / %d" % [done, TARGET]
	var state := State.IDLE
	if completed >= TARGET:
		state = State.DONE
	elif _is_active(desk) or discovered > 0:
		state = State.ACTIVE
	out["state"] = state
	match state:
		State.DONE:
			out["state_text"] = "ВЫПОЛНЕНО"
		State.ACTIVE:
			out["state_text"] = "В ПРОЦЕССЕ"
		_:
			out["state_text"] = "НЕ НАЧАТО"
	return out


## Is the desk working on something right now?
static func _is_active(desk: Object) -> bool:
	if desk.has_method("is_researching"):
		return bool(desk.call("is_researching"))
	return false
