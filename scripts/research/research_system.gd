extends ShipComponent
class_name ResearchSystem

const RESEARCH_PROFILE := preload("res://scripts/research/research_profile.gd")

## The ship's research desk: it takes objects the scanner found and turns
## them into research XP and revealed data, one subject at a time.
##
## This is a `ShipComponent`, so it mounts under `Ship/Systems` exactly like
## the scanner, draws power through the same bus, and answers `equipment_status()`
## through the same seam. It never touches `ShipController` and never talks to
## another component directly - it publishes on the bus and emits Godot signals
## for whoever holds it (a panel, a test, the save system).
##
## What research is:
##
## 1. a scanner contact is offered to the research desk (`research_available`);
## 2. the pilot orders analysis of one contact (`start_research`);
## 3. the desk integrates over time, one subject at a time, with the ship's
##    condition slowing a damaged desk down;
## 4. on completion, XP is awarded once per subject and the subject's data is
##    revealed (`research_completed`);
## 5. the order can be cut short (`cancel_research`) and resumed later -
##    progress is stored per subject and survives chunk unloads.
##
## What it deliberately does not do: no UI, no upgrade system, no discovery
## log, no ship-side objects. It answers "analyse this" and stops. A panel is
## its own sub-stage.

## Analysis started on one subject. Carries the subject id, its type id and
## how long the analysis will take.
signal research_started(subject_id: String, type_id: String, time_required: float)
## Analysis in progress: how far through, 0..1. Emitted each physics frame
## while a subject is under analysis.
signal research_progress(subject_id: String, progress: float)
## Analysis finished. `xp_awarded` is zero when the subject was already
## analysed before; `was_new` is false in that case. `data` is the revealed
## information dictionary, empty when the subject has nothing to reveal.
signal research_completed(subject_id: String, type_id: String, xp_awarded: int,
	was_new: bool, data: Dictionary)
## Analysis cut short. Nothing is refunded - the time already spent is kept
## in the subject's saved progress. `reason` is "switched_off", "unpowered"
## or "aborted".
signal research_cancelled(subject_id: String, reason: String)
## Research XP changed. `amount` is the delta, `total` is the new running total.
signal xp_gained(amount: int, total: int)
## Research XP spent. `amount` is the delta (positive), `total` is the new running total.
signal xp_spent(amount: int, total: int)
## A scanner contact that this profile knows how to research and that has not
## been fully analysed yet. Carries the contact dictionary from the scanner.
signal research_available(contact: Dictionary)

## The research profile: which kinds of thing can be analysed, how long each
## takes and what each pays. Replaced at run time by an upgrade; never edited
## in place per ship clone.
@export var profile = RESEARCH_PROFILE.new()
## When true, the desk automatically subscribes to the scanner it finds in the
## tree and raises `research_available` for every new contact a sweep turns up.
@export var auto_subscribe: bool = true
## Multiplies every analysis time. A damaged desk is slower; a future upgrade
## is faster.
@export_range(0.1, 8.0, 0.05) var time_multiplier: float = 1.0

## The subject under analysis right now, or "" when the desk is idle.
var _current_subject: String = ""
## The type of the subject under analysis, or "".
var _current_type: String = ""
## How long this subject needs in seconds, after multipliers.
var _required_time: float = 0.0
## Seconds already spent on the current subject this session.
var _elapsed: float = 0.0
## Running total of research XP, across all subjects and all sessions.
var _xp: int = 0
## One entry per subject ever analysed:
##   { "type_id": String, "progress": Float 0..1, "completed": Bool,
##     "xp_awarded": Int, "data": Dictionary }
var _progress: Dictionary = {}

## The group the scanner node joins. Kept in sync with whatever scene mounts
## the scanner under; the scanner itself does not join this group yet, so the
## tree walk is the fallback.
const SCANNER_GROUP := "scanner"
## A sweep may not be shorter than this, whatever the profile says.
const MIN_ANALYSIS_SECONDS := 0.1

## Hook the desk into the scanner when both are in the tree. The scanner is
## found by group or by walking up from the hull, the same injection rule the
## scanner itself uses for the world field.
func _ready() -> void:
	super()
	set_physics_process(false)
	if profile == null:
		profile = RESEARCH_PROFILE.new()
	state_changed.connect(_on_state_changed)
	enabled_changed.connect(_on_enabled_changed)
	_find_scanner()


## ----------------------------------------------------------------- the command ---

## Offer one contact to the research desk. Returns true when the desk accepts
## it and begins analysis. Refused when: already analysing, the desk is
## offline or unpowered, the profile does not know the contact, or the contact
## has already been fully analysed. Nothing is spent on a refusal.
func start_research(contact: Dictionary) -> bool:
	if contact == null or contact.is_empty():
		return _refuse("no_contact")
	if _current_subject != "":
		return _refuse("busy")
	if not is_operational():
		return _refuse("unpowered" if enabled else "switched_off")
	var rtype
	rtype = profile.type_for(contact)
	if rtype == null:
		return _refuse("unknown_type")
	var subject_id := _subject_id_of(contact)
	if subject_id == "":
		return _refuse("no_id")
	if _is_completed(subject_id):
		return _refuse("already_done")
	_current_subject = subject_id
	_current_type = rtype.type_id
	_required_time = maxf(rtype.time_value() * time_multiplier * _health_scale(0.5, 1.0),
		MIN_ANALYSIS_SECONDS)
	_elapsed = _progress_for(subject_id).get("progress", 0.0) * _required_time
	if _elapsed >= _required_time:
		# Saved progress already meets the requirement - finish immediately.
		_finish()
		return true
	_scanning = true
	set_physics_process(true)
	research_started.emit(_current_subject, _current_type, _required_time)
	return true


## Cut analysis short. Progress already spent is saved in the subject's entry.
## Nothing is refunded. Can be resumed later with `start_research()`.
func cancel_research(reason := "aborted") -> void:
	if _current_subject == "":
		return
	# Save how far we got before clearing.
	var entry := _progress_for(_current_subject)
	entry["progress"] = clampf(_elapsed / _required_time, 0.0, 1.0) if _required_time > 0.0 else 0.0
	entry["completed"] = false
	_progress[_current_subject] = entry
	var subject := _current_subject
	_current_subject = ""
	_current_type = ""
	_required_time = 0.0
	_elapsed = 0.0
	_scanning = false
	set_physics_process(false)
	research_cancelled.emit(subject, reason)


## Is the desk analysing something right now?
func is_researching() -> bool:
	return _current_subject != ""


## How far through the current subject, 0..1. Reads 0 when idle.
func progress() -> float:
	if not _scanning or _required_time <= 0.0:
		return 0.0
	return clampf(_elapsed / _required_time, 0.0, 1.0)


## How far through subject `subject_id` is, 0..1, from saved progress.
## Returns 0 for a subject nobody has touched.
func subject_progress(subject_id: String) -> float:
	return _progress_for(subject_id).get("progress", 0.0)


## Has subject `subject_id` been fully analysed already?
func is_completed(subject_id: String) -> bool:
	return _is_completed(subject_id)


## The running total of research XP.
func get_xp() -> int:
	return _xp

## Spend `amount` research XP. Returns false (and spends nothing) when the
## desk does not hold enough XP. Emits `xp_spent` on success.
func spend_xp(amount: int) -> bool:
	if amount <= 0:
		return false
	if _xp < amount:
		return false
	_xp -= amount
	xp_spent.emit(amount, _xp)
	return true


## How much XP subject `subject_id` has already awarded. Zero when never
## analysed or already completed without XP.
func subject_xp(subject_id: String) -> int:
	return int(_progress_for(subject_id).get("xp_awarded", 0))


## Can this contact be researched right now? Same checks as `start_research`
## without starting anything.
func can_research(contact: Dictionary) -> bool:
	if contact == null or contact.is_empty():
		return false
	if _current_subject != "":
		return false
	if not is_operational():
		return false
	var type
	type = profile.type_for(contact)
	if type == null:
		return false
	var subject_id := _subject_id_of(contact)
	if subject_id == "":
		return false
	return not _is_completed(subject_id)


## The research type that would answer for this contact, or null.
func type_for(contact: Dictionary):
	if profile == null:
		return null
	return profile.type_for(contact)


## The saved entry for one subject, creating it on first touch.
func _progress_for(subject_id: String) -> Dictionary:
	if not _progress.has(subject_id):
		_progress[subject_id] = {
			"type_id": "",
			"progress": 0.0,
			"completed": false,
			"xp_awarded": 0,
			"data": {},
		}
	return _progress[subject_id] as Dictionary


## Is one subject fully done, from saved progress.
func _is_completed(subject_id: String) -> bool:
	return bool(_progress_for(subject_id).get("completed", false))


## A stable id for a contact, the same shape the scanner uses: `chunk:item` for
## world objects, `sig:x,y` for phantom signals. Falls back to a combination
## of signature and position when nothing stable exists.
func _subject_id_of(contact: Dictionary) -> String:
	var id := String(contact.get("id", ""))
	if not id.is_empty():
		return id
	# Fallback: build one from what we have. Honest but not stable across
	# chunk unloads - the caller should prefer the scanner's own id.
	var sig := String(contact.get("signature", ""))
	var pos: Vector2 = contact.get("position", Vector2.ZERO)
	if pos is Vector2:
		return "%s:%.0f,%.0f" % [sig, pos.x, pos.y]
	return sig


## ------------------------------------------------------------------- analysis ---

func _physics_process(delta: float) -> void:
	if not _scanning:
		set_physics_process(false)
		return
	if not enabled:
		cancel_research("switched_off")
		return
	if not is_operational():
		cancel_research("unpowered")
		return
	_elapsed = minf(_elapsed + maxf(delta, 0.0) * _rate_scale(), _required_time)
	research_progress.emit(_current_subject, progress())
	if _elapsed >= _required_time:
		_finish()


## How fast the desk integrates right now. Damage slows it; the health scale
## mirrors the scanner's rule (integrity, not efficiency).
func _rate_scale() -> float:
	return _health_scale(0.4, 1.0)


func _finish() -> void:
	var entry := _progress_for(_current_subject)
	entry["type_id"] = _current_type
	entry["progress"] = 1.0
	entry["completed"] = true
	# Reveal data: the contact's own `info` dictionary, duplicated so the
	# caller cannot write through into the scanner's contact.
	var data := {}
	var contact := _last_contact_for(_current_subject)
	if contact != null:
		var info: Dictionary = contact.get("info", {})
		if info is Dictionary:
			data = info.duplicate(true)
	_progress[_current_subject] = entry
	var xp_awarded := 0
	var was_new := false
	if entry.get("xp_awarded", 0) == 0:
		var rtype
		rtype = profile.type(_current_type) if profile != null else null
		if rtype != null:
			xp_awarded = int(rtype.xp_value())
		entry["xp_awarded"] = xp_awarded
		_progress[_current_subject] = entry
		_xp += xp_awarded
		was_new = true
		xp_gained.emit(xp_awarded, _xp)
	_publish_completed(_current_subject, _current_type, xp_awarded, was_new, data)
	var subject := _current_subject
	var type_id := _current_type
	_current_subject = ""
	_current_type = ""
	_required_time = 0.0
	_elapsed = 0.0
	_scanning = false
	set_physics_process(false)
	research_completed.emit(subject, type_id, xp_awarded, was_new, data)


## Publish the completion on the ship's bus so any system can react without
## knowing the research desk exists.
func _publish_completed(subject_id: String, type_id: String, xp: int,
	was_new: bool, data: Dictionary) -> void:
	publish("research_completed", {
		"subject": subject_id,
		"type": type_id,
		"xp": xp,
		"was_new": was_new,
		"data": data.duplicate(true),
		"at": ShipSystemEvent.now(),
	})


## The scanner's last contact list, searched for our current subject. Used to
## pull the contact's `info` into the revealed data.
func _last_contact_for(subject_id: String) -> Dictionary:
	var scanner := _resolved_scanner()
	if scanner == null or not is_instance_valid(scanner):
		return {}
	if scanner.has_method("last_contacts"):
		var contacts: Array = scanner.call("last_contacts")
		if contacts is Array:
			for contact in contacts:
				if contact is Dictionary and String(contact.get("id", "")) == subject_id:
					return contact
	return {}


## ----------------------------------------------------------------- scanner link ---

## Find the scanner node: by group, then by walking up and sideways from the
## hull looking for a ShipScanner, then by scanning the tree. Called once in
## `_ready()`.
func _find_scanner() -> void:
	if is_inside_tree():
		var group_node := get_tree().get_first_node_in_group(SCANNER_GROUP)
		if group_node != null and is_instance_valid(group_node):
			_scanner = group_node
			_connect_scanner()
			return
	# Walk up from the hull, then check siblings at each level: the scanner is
	# mounted under Ship/Systems alongside us.
	var node := get_parent()
	while node != null:
		if node is ShipScanner:
			_scanner = node
			_connect_scanner()
			return
		for child in node.get_children():
			if child is ShipScanner and child != self:
				_scanner = child
				_connect_scanner()
				return
		node = node.get_parent()


## The scanner we are connected to, or null. Resolved live each call because
## the scanner node can be reloaded.
func _resolved_scanner() -> Node:
	if _scanner != null and is_instance_valid(_scanner):
		return _scanner
	_find_scanner()
	return _scanner


## Hook signals onto the scanner we found.
func _connect_scanner() -> void:
	if _scanner == null or not is_instance_valid(_scanner):
		return
	if _scanner.has_method("scan_completed"):
		_scanner.scan_completed.connect(_on_scan_completed)
	if _scanner.has_method("contact_found"):
		_scanner.contact_found.connect(_on_contact_found)


## The scanner finished a sweep. Offer every contact that this profile knows
## about and that is not yet fully analysed.
func _on_scan_completed(contacts: Array) -> void:
	if not auto_subscribe:
		return
	for contact in contacts:
		if contact is Dictionary and profile.type_for(contact) != null:
			if not _is_completed(_subject_id_of(contact)):
				research_available.emit(contact.duplicate(true))


## One contact arrived during a sweep. Offer it immediately so a panel can
## show it without waiting for the sweep to end.
func _on_contact_found(contact: Dictionary) -> void:
	if not auto_subscribe:
		return
	if contact is Dictionary and profile.type_for(contact) != null:
		if not _is_completed(_subject_id_of(contact)):
			research_available.emit(contact.duplicate(true))


## ------------------------------------------------------------------- state ---

func _on_state_changed(_previous: int, current: int) -> void:
	if not ShipSystemState.is_operational(current):
		if _scanning:
			cancel_research("unpowered" if enabled else "switched_off")


func _on_enabled_changed(value: bool) -> void:
	if _scanning and not value:
		cancel_research("switched_off")


## A health multiplier like the scanner's: a damaged desk works slower.
func _health_scale(floor_at: float, ceiling: float) -> float:
	return lerpf(floor_at, ceiling, clampf(integrity, 0.0, 1.0))


## Why the last `start_research()` was refused, or "".
func refuse_reason() -> String:
	return _refuse_reason


## Save the desk's state: XP and every subject's progress. For a save file.
func to_dict() -> Dictionary:
	return {
		"xp": _xp,
		"progress": _progress.duplicate(true),
	}


## Load state previously written by `to_dict()`. Returns false on a bad
## payload and leaves the desk untouched in that case.
func from_dict(data: Dictionary) -> bool:
	if not data is Dictionary:
		return false
	var xp: int = int(data.get("xp", 0))
	if xp is int:
		_xp = xp
	var progress: Dictionary = data.get("progress", {})
	if progress is Dictionary:
		_progress = progress.duplicate(true)
	return true


## The desk's status, for `equipment_status()` and panels.
func status() -> Dictionary:
	var out := super()
	out["researching"] = _scanning
	out["research_progress"] = progress()
	out["research_subject"] = _current_subject
	out["research_type"] = _current_type
	out["research_xp"] = _xp
	out["research_subjects"] = _progress.size()
	out["research_last_refusal"] = _refuse_reason
	return out


## Refuse an order and record the reason.
func _refuse(reason: String) -> bool:
	_refuse_reason = reason
	return false


## A scanner reference found through the tree. Kept as a fallback field.
var _scanner: Node = null
## The last refusal reason.
var _refuse_reason: String = ""
## Whether analysis is running right now.
var _scanning: bool = false
