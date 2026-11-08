class_name ResearchSnapshot
extends RefCounted

## The research panel's picture of the real research desk.
##
## Every subject on the panel is a subject the desk itself knows about: the
## desk's own progress file says which ones it has seen, how far it got with
## each, what it paid out and whether the analysis is finished. The scanner is
## asked only for a title and a class, so the pilot reads a name instead of a
## chunk id.
##
## Nothing here starts, stops or scores anything.

## Build the panel's picture out of the desk.
static func build(desk: Node, scanner: Node) -> Dictionary:
	var out := {
		"objects": [] as Array[ResearchObject],
		"xp": 0,
		"current": "",
		"desk_online": false,
	}
	if desk == null or not is_instance_valid(desk):
		return out
	var xp := 0
	if desk.has_method("get_xp"):
		xp = int(desk.call("get_xp"))
	out["xp"] = xp
	var current := ""
	if desk.has_method("status"):
		var status: Variant = desk.call("status")
		if status is Dictionary:
			current = str((status as Dictionary).get("research_subject", ""))
	out["current"] = current
	var online := false
	if desk.has_method("is_operational"):
		online = bool(desk.call("is_operational"))
	out["desk_online"] = online
	var data: Dictionary = {}
	if desk.has_method("to_dict"):
		var raw: Variant = desk.call("to_dict")
		if raw is Dictionary:
			data = raw as Dictionary
	var progress: Dictionary = data.get("progress", {})
	var objects: Array[ResearchObject] = []
	for subject_id in progress:
		var entry: Variant = progress[subject_id]
		if not entry is Dictionary:
			continue
		objects.append(_object_for(subject_id, entry as Dictionary, desk, scanner,
			current, xp))
	out["objects"] = objects
	return out


## One subject, as the panel shows it.
static func _object_for(subject_id: String, entry: Dictionary, desk: Node,
		scanner: Node, current: String, xp: int) -> ResearchObject:
	var object := ResearchObject.new()
	object.id = subject_id
	var type_id := str(entry.get("type_id", ""))
	var type := _type_of(desk, type_id)
	object.type_label = str(type.call("label")) if type != null else "НЕИЗВЕСТНЫЙ ОБЪЕКТ"
	object.title = _title_for(scanner, subject_id, object.type_label)
	object.category = "КОСМИЧЕСКИЙ ОБЪЕКТ"
	var completed := bool(entry.get("completed", false))
	var progress := clampf(float(entry.get("progress", 0.0)), 0.0, 1.0)
	var is_current := subject_id == current
	if is_current and desk.has_method("progress"):
		progress = clampf(float(desk.call("progress")), 0.0, 1.0)
	object.progress = progress
	object.state = _state_for(completed, progress, is_current)
	object.xp_awarded = int(entry.get("xp_awarded", 0))
	object.xp_total = xp
	object.knowledge_level = _knowledge_of(entry)
	object.knowledge_max = maxi(object.knowledge_level, 1)
	object.time_total = _time_total(desk, type)
	object.time_remaining = maxf(object.time_total * (1.0 - progress), 0.0)
	var revealed: Variant = entry.get("data", {})
	if revealed is Dictionary:
		for key in (revealed as Dictionary):
			object.discovered_properties.append(str(key))
	object.description = _description_for(object)
	object.is_new = not completed and progress <= 0.0
	object.is_rare = type != null and bool(type.get("rare"))
	object.notification = "ИССЛЕДОВАНИЕ ЗАВЕРШЕНО" if completed else ""
	return object


## The state word the panel shows, from the desk's own three facts.
static func _state_for(completed: bool, progress: float, is_current: bool) -> int:
	if completed:
		return ResearchObject.State.COMPLETED
	if is_current:
		return ResearchObject.State.IN_PROGRESS
	if progress > 0.0:
		return ResearchObject.State.PAUSED
	return ResearchObject.State.AVAILABLE


## The research type behind a subject, from the desk's own profile.
static func _type_of(desk: Node, type_id: String) -> Resource:
	if type_id.is_empty() or desk == null or not is_instance_valid(desk):
		return null
	var profile: Variant = desk.get("profile")
	if profile == null or not is_instance_valid(profile):
		return null
	if not profile.has_method("type"):
		return null
	return profile.call("type", type_id) as Resource


## The title the scanner gave this object, if it is still in the last sweep.
static func _title_for(scanner: Node, subject_id: String, fallback: String) -> String:
	if scanner != null and is_instance_valid(scanner) and scanner.has_method("last_contacts"):
		var raw: Variant = scanner.call("last_contacts")
		if raw is Array:
			for entry in (raw as Array):
				if entry is Dictionary and str((entry as Dictionary).get("id", "")) == subject_id:
					var title := str((entry as Dictionary).get("title", ""))
					if not title.is_empty():
						return title.to_upper()
	return fallback.to_upper()


## How long one analysis takes, by the desk's own formula: the type's time,
## the desk's multiplier and its own condition.
static func _time_total(desk: Node, type: Resource) -> float:
	if type == null:
		return 0.0
	var base := 0.0
	if type.has_method("time_value"):
		base = float(type.call("time_value"))
	if desk != null and is_instance_valid(desk):
		base *= lerpf(0.5, 1.0, clampf(float(desk.get("integrity")), 0.0, 1.0))
		base *= float(desk.get("time_multiplier"))
	return base


## What the desk learned about the object: the keys it revealed.
static func _knowledge_of(entry: Dictionary) -> int:
	var revealed: Variant = entry.get("data", {})
	if revealed is Dictionary:
		return (revealed as Dictionary).size()
	return 0


## One line about the subject, from the desk's own record.
static func _description_for(object: ResearchObject) -> String:
	if object.state == ResearchObject.State.COMPLETED:
		return "Анализ завершён. Изучено свойств: %d." % object.knowledge_level
	if object.state == ResearchObject.State.IN_PROGRESS:
		return "Анализ идёт. Осталось примерно %s." % ResearchObject.format_time(object.time_remaining)
	if object.progress > 0.0:
		return "Анализ прерван на %d%% и может быть продолжен." % int(roundf(object.progress * 100.0))
	return "Объект обнаружен и ожидает анализа."
