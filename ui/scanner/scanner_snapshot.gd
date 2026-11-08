class_name ScannerSnapshot
extends RefCounted

## The scanner screen's picture of the real scanner.
##
## Every number comes from the ship: the scanner's own last sweep, its own
## state, the research desk's own progress, the hull's own energy reserve. The
## screen shows this and counts nothing of its own, so the scope cannot
## disagree with the dish that swept.
##
## The presentation model is the screen's own `ScannerContact`; this file only
## fills it from the gameplay data.

## What the scope is doing. The same six words the screen knows.
enum State { READY, SCANNING, CONTACTS_FOUND, NO_CONTACTS, LOW_ENERGY, MALFUNCTION }

## Below this share of the reserve the scanner cannot be trusted to pay for a
## sweep, and the screen says so instead of pretending it can.
const LOW_ENERGY_RATIO := 0.2

## How a contact's distance reads on the screen: the world works in pixels and
## the screen speaks in kilometres.
const PIXELS_PER_KM := 1000.0

## The dish's own range in pixels, used to place a contact in the scope.
const SCOPE_RANGE := 880.0


## Read the ship and build the screen's picture.
##
## `scanner` is the mounted scanner (or null), `desk` the research desk (or
## null), `hull` the ship (or null) and `energy_ratio` the hull's own reserve
## share, 0..1.
static func build(scanner: Node, desk: Node, hull: Node2D, energy_ratio: float) -> Dictionary:
	var out := {
		"state": State.READY,
		"contacts": [] as Array[ScannerContact],
		"progress": 0.0,
		"remaining": 0.0,
		"readiness": 1.0,
		"status_text": "",
		"action_label": "НАЧАТЬ ОБХОД",
		"can_scan": false,
		"state_name": "",
	}
	if scanner == null or not is_instance_valid(scanner):
		out["state"] = State.MALFUNCTION
		out["state_name"] = "НЕИСПРАВЕН"
		out["status_text"] = "СКАНЕР НЕ СМОНТИРОВАН"
		out["action_label"] = "НЕТ УСТРОЙСТВА"
		out["readiness"] = 0.0
		return out
	out["readiness"] = clampf(float(energy_ratio), 0.0, 1.0)
	var contacts := _contacts_of(scanner, desk, hull)
	out["contacts"] = contacts
	var scanning := false
	if scanner.has_method("is_scanning"):
		scanning = bool(scanner.call("is_scanning"))
	if scanner.has_method("progress"):
		out["progress"] = clampf(float(scanner.call("progress")), 0.0, 1.0)
	var sweep_seconds := 0.0
	if scanner.has_method("sweep_seconds_now"):
		sweep_seconds = float(scanner.call("sweep_seconds_now"))
	out["remaining"] = maxf(sweep_seconds * (1.0 - float(out["progress"])), 0.0)
	var operational := true
	if scanner.has_method("is_operational"):
		operational = bool(scanner.call("is_operational"))
	if scanning:
		out["state"] = State.SCANNING
		out["state_name"] = "СКАНИРОВАНИЕ"
		out["status_text"] = "РЕШЕТО: В РАБОТЕ"
		out["action_label"] = "ОБХОД ИДЁТ"
		out["can_scan"] = false
	elif not operational:
		out["state"] = State.MALFUNCTION
		out["state_name"] = "НЕИСПРАВЕН"
		out["status_text"] = "ПРИБОР НЕИСПРАВЕН"
		out["action_label"] = "НЕИСПРАВЕН"
		out["can_scan"] = false
	elif float(energy_ratio) < LOW_ENERGY_RATIO:
		out["state"] = State.LOW_ENERGY
		out["state_name"] = "НИЗКАЯ ЭНЕРГИЯ"
		out["status_text"] = "РЕЗЕРВ НЕДОСТАТОЧЕН ДЛЯ ОБХОДА"
		out["action_label"] = "МАЛО ЭНЕРГИИ"
		out["can_scan"] = false
	elif not contacts.is_empty():
		out["state"] = State.CONTACTS_FOUND
		out["state_name"] = "КОНТАКТЫ НАЙДЕНЫ"
		out["status_text"] = "РЕЗУЛЬТАТ ПОСЛЕДНЕГО ОБХОДА"
		out["action_label"] = "ПОВТОРИТЬ ОБХОД"
		out["can_scan"] = true
	else:
		out["state"] = State.READY
		out["state_name"] = "ГОТОВ"
		out["status_text"] = "РЕШЕТО: СВОБОДНО"
		out["action_label"] = "НАЧАТЬ ОБХОД"
		out["can_scan"] = true
	return out


## The contacts of the last sweep, each one dressed for the screen and matched
## with the research desk's own answer about it.
static func _contacts_of(scanner: Node, desk: Node, hull: Node2D) -> Array[ScannerContact]:
	var out: Array[ScannerContact] = []
	var raw: Array = []
	if scanner.has_method("last_contacts"):
		var found: Variant = scanner.call("last_contacts")
		if found is Array:
			raw = found as Array
	var origin := Vector2.ZERO
	if hull != null and is_instance_valid(hull):
		origin = hull.global_position
	for entry in raw:
		if not entry is Dictionary:
			continue
		var contact := entry as Dictionary
		var type_label := _type_label(desk, contact)
		var data := {
			"id": str(contact.get("id", "SIG-UNKNOWN")),
			"title": str(contact.get("title", "")),
			"type": type_label,
			"distance": _distance_text(contact),
			"position": _normalized(contact, origin),
			"research_status": _research_status(desk, contact),
			"analysis_available": _can_analyse(desk, contact),
			"description": _description_of(contact, type_label),
			"anomaly": _mentions(type_label, ["АНОМАЛ", "ANOMALY"]),
			"unknown": _mentions(type_label, ["НЕИЗВЕСТ", "UNKNOWN"]),
		}
		out.append(ScannerContact.from_dictionary(data))
	return out


## The distance from the hull, in the screen's own units.
static func _distance_text(contact: Dictionary) -> String:
	var px := float(contact.get("distance", 0.0))
	return "%.1f КМ" % (px / PIXELS_PER_KM)


## Where the contact sits in the scope: -1..1 on both axes, relative to the
## hull and scaled by the dish's own range.
static func _normalized(contact: Dictionary, origin: Vector2) -> Vector2:
	var at: Vector2 = contact.get("position", Vector2.ZERO)
	return Vector2(
		clampf((at.x - origin.x) / SCOPE_RANGE, -1.0, 1.0),
		clampf((at.y - origin.y) / SCOPE_RANGE, -1.0, 1.0))


## The research type that answers for this contact, in the screen's words.
static func _type_label(desk: Node, contact: Dictionary) -> String:
	if desk != null and is_instance_valid(desk) and desk.has_method("type_for"):
		var type: Variant = desk.call("type_for", contact)
		if type != null and type.has_method("label"):
			return str(type.call("label"))
	var title := str(contact.get("title", ""))
	if title.is_empty():
		return "НЕИЗВЕСТНЫЙ ОБЪЕКТ"
	return title.to_upper()


## One line about the contact, from the information the sweep revealed.
static func _description_of(contact: Dictionary, type_label: String) -> String:
	var info: Variant = contact.get("info", {})
	if info is Dictionary and not (info as Dictionary).is_empty():
		var parts: Array[String] = []
		for key in (info as Dictionary):
			parts.append("%s: %s" % [str(key), str((info as Dictionary)[key])])
		return "  ".join(parts)
	return "Объект класса %s. Данных пока нет." % type_label.to_upper()


## What the research desk says about this contact's analysis.
static func _research_status(desk: Node, contact: Dictionary) -> String:
	if desk == null or not is_instance_valid(desk):
		return "ИССЛЕДОВАТЕЛЬ НЕ ПОДКЛЮЧЁН"
	var id := str(contact.get("id", ""))
	if id.is_empty():
		return "НЕ ИДЕНТИФИЦИРОВАН"
	if desk.has_method("is_completed") and bool(desk.call("is_completed", id)):
		return "ИССЛЕДОВАНИЕ ЗАВЕРШЕНО"
	if desk.has_method("subject_progress"):
		var progress := float(desk.call("subject_progress", id))
		if progress > 0.0:
			return "ИССЛЕДОВАНИЕ %d%%" % int(roundf(progress * 100.0))
	return "НЕ ИССЛЕДОВАН"


## Can the desk take this contact right now?
static func _can_analyse(desk: Node, contact: Dictionary) -> bool:
	if desk == null or not is_instance_valid(desk):
		return false
	if not desk.has_method("can_research"):
		return false
	return bool(desk.call("can_research", contact))


## Does the text say any of these words?
static func _mentions(text: String, words: Array[String]) -> bool:
	var upper := text.to_upper()
	for word in words:
		if upper.contains(word.to_upper()):
			return true
	return false
