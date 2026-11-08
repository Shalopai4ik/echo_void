extends Node
class_name MissionDirector

## The demo's one storyline, from arrival to the escape from the Source.
##
## It owns no mechanic. It watches the ship's real systems - the scanner's
## switch and sweeps, the desk's finished analyses, the hull - and when a
## condition holds it moves the story on: it says the next lines over comms,
## places the next story object, aims the waypoint, and turns the threat up
## (`ThreatAttention.threat_scale`, `Leviathan.aggression`,
## `AtmosphereDirector.level`). The flight HUD reads `objective_title()` and
## `objective_lines()` through the "mission" group it already looked for.
##
## Nothing is gated behind a purchase: every objective can be done with the
## ship as it starts. Upgrades make it easier, never possible.

signal chapter_changed(index: int, title: String)
signal objective_changed()
signal mission_finished(victory: bool)

const GROUP := "mission"
const WORLD_PAUSABLE_GROUP := "world_pausable"
const Story := preload("res://scripts/mission/mission_story.gd")

## Seconds between two comms lines from one batch.
@export var line_gap_sec: float = 4.5
## How close the hull must be to the extraction point to end the demo.
@export var extraction_radius: float = 1100.0

var _chapter: int = -1
var _check_in: float = 0.0
var _queue: Array = []
var _queue_wait: float = 1.5
var _scans: int = 0
var _studied: int = 0
var _xp_earned: int = 0
var _beacons_done: int = 0
var _nodes_done: int = 0
var _source_mid_said: bool = false
var _finished: bool = false
var _death_timer: float = -1.0
var _flags: Dictionary = {}

var _ship: Node2D
var _systems: Node
var _scanner: Node
var _desk: Node
var _field: POIField
var _attention: ThreatAttention
var _leviathan: Leviathan
var _atmosphere: AtmosphereDirector
var _route: Dictionary = Story.route()


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(WORLD_PAUSABLE_GROUP)
	call_deferred("_bind")


func _bind() -> void:
	var tree := get_tree()
	# A new run starts with a silent sky: the broadcaster is an autoload and
	# would otherwise keep the last run's flares and decoys on the air.
	var air := tree.get_root().get_node_or_null("SignalBroadcaster")
	if air != null and air.has_method("clear_all"):
		air.call("clear_all")
	_ship = GameNodes.ship(tree)
	if _ship != null:
		_systems = _ship.get_node_or_null("Systems")
	if _systems != null:
		_scanner = _systems.get_node_or_null("Scanner")
		_desk = _systems.get_node_or_null("Research")
		if _systems.has_signal("hull_destroyed"):
			_systems.connect("hull_destroyed", _on_hull_destroyed)
	if _scanner != null and _scanner.has_signal("scan_completed"):
		_scanner.connect("scan_completed", func(_c: Array) -> void: _scans += 1)
	if _desk != null:
		_desk.connect("research_completed", _on_research_completed)
		_desk.connect("research_started", _on_research_started)
		_desk.connect("xp_gained", func(amount: int, _total: int) -> void: _xp_earned += amount)
	_field = tree.get_first_node_in_group(POIField.GROUP) as POIField
	_attention = tree.get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
	_leviathan = tree.get_first_node_in_group(Leviathan.GROUP) as Leviathan
	_atmosphere = tree.get_first_node_in_group(AtmosphereDirector.GROUP) as AtmosphereDirector
	_start_chapter(0)


## ----------------------------------------------------------------- HUD read ---

func chapter() -> int:
	return _chapter


func chapter_title() -> String:
	if _chapter < 0:
		return ""
	return str(Story.CHAPTERS[_chapter]["title"])


## The rows' own heading; the chapter itself is on the corner card.
func objective_title() -> String:
	return "ЗАДАЧИ" if _chapter >= 0 else ""


## Up to three lines for the HUD rows. Done goals carry a tick.
func objective_lines() -> Array:
	var lines: Array = []
	match _chapter:
		0:
			lines.append(_goal("Включить сканер [1]", _flag("scanner_on")))
			lines.append(_goal("Обход сканером [R]", _flag("scanned")))
			if not _flag("scanned"):
				pass
			elif not _flag("desk_on"):
				lines.append(_goal("Включить исследовательский стол [2]", false))
			else:
				lines.append(_goal("Изучить объект [N]", _flag("studied")))
		1:
			lines.append(_goal("Изучить маяки «Пелагии»: %d / 3" % _beacons_done, _beacons_done >= 3))
			lines.append("  Маркер ведёт к следующему маяку")
		2:
			lines.append(_goal("Найти корпус «Пелагии»", _flag("pelagia_seen")))
			lines.append(_goal("Изучить «Пелагию» (60 с)", _flag("pelagia_done")))
		3:
			lines.append(_goal("Изучить резонансные узлы: %d / 3" % _nodes_done, _nodes_done >= 3))
		4:
			if not _flag("source_done"):
				lines.append(_goal("Достичь Источника", _flag("source_seen")))
				lines.append(_goal("Изучить Источник (90 с)", false))
			else:
				lines.append(_goal("Изучить Источник", true))
				lines.append(_goal("Уйти на точку эвакуации", false))
	if _desk != null and _desk.has_method("is_out_of_range") and bool(_desk.call("is_out_of_range")):
		lines.append("! Анализ ждёт: вернитесь к объекту")
	while lines.size() > 3:
		lines.pop_back()
	return lines


## Where the pilot should go next: {"position": Vector2, "label": String}, or {}.
func waypoint() -> Dictionary:
	match _chapter:
		0:
			if _flag("scanned") and not _flag("studied"):
				return {"position": _route["tutorial_wreck"], "label": "ОБЛОМОК"}
		1:
			if _beacons_done < 3:
				return {"position": _route["beacon_%d" % (_beacons_done + 1)],
					"label": "МАЯК %d" % (_beacons_done + 1)}
		2:
			if not _flag("pelagia_done"):
				return {"position": _route["pelagia"], "label": "«ПЕЛАГИЯ»"}
		3:
			for i in range(1, 4):
				if not _story_done("node_%d" % i):
					return {"position": _route["node_%d" % i], "label": "УЗЕЛ %d" % i}
		4:
			if not _flag("source_done"):
				return {"position": _route["source"], "label": "ИСТОЧНИК"}
			return {"position": _route["extraction"], "label": "ЭВАКУАЦИЯ"}
	return {}


## Numbers for the final screen.
func stats() -> Dictionary:
	var clock := get_tree().get_first_node_in_group(SessionClock.GROUP) as SessionClock
	var upgrades := 0
	var desk_mgr := _systems.get_node_or_null("UpgradeDesk") if _systems != null else null
	if desk_mgr != null and desk_mgr.has_method("to_dict"):
		var levels: Dictionary = desk_mgr.call("to_dict").get("levels", {})
		for k in levels:
			upgrades += int(levels[k])
	return {
		"time": clock.time_text() if clock != null else "--:--:--",
		"studied": _studied,
		"xp": _xp_earned,
		"upgrades": upgrades,
		"chapter": _chapter + 1,
	}


func is_finished() -> bool:
	return _finished


## ------------------------------------------------------------------ chapters ---

func _start_chapter(index: int) -> void:
	_chapter = index
	var info: Dictionary = Story.CHAPTERS[index]
	if _attention != null:
		_attention.threat_scale = float(info["scale"])
	if _leviathan != null:
		_leviathan.set_aggression(int(info["aggression"]))
	if _atmosphere != null:
		_atmosphere.set_level(int(info["atmosphere"]))
	GameFeed.notify(get_tree(), GameFeed.INFO, "МИССИЯ", str(info["title"]))
	match index:
		0:
			_say_batch(Story.INTRO)
			_place("tutorial_wreck", "wreck_fragment")
			_place("tutorial_crystal", "crystal")
		1:
			_say_batch(Story.TRAIL_START)
			for i in range(1, 4):
				_place("beacon_%d" % i, "story_beacon")
		2:
			_say_batch(Story.PRESENCE_START)
			_place("pelagia", "pelagia")
		3:
			_say_batch(Story.DEPTH_START)
			for i in range(1, 4):
				_place("node_%d" % i, "resonance_node")
		4:
			_place("source", "source")
	chapter_changed.emit(index, str(info["title"]))
	objective_changed.emit()


func _physics_process(delta: float) -> void:
	_tick_comms(delta)
	if _death_timer >= 0.0:
		_death_timer += delta
		if _death_timer > 2.5 and not _finished:
			_finish(false)
		return
	_check_in -= delta
	if _check_in > 0.0 or _finished:
		return
	_check_in = 0.25
	_check()


func _check() -> void:
	match _chapter:
		0:
			if not _flag("scanner_on") and _scanner != null and bool(_scanner.get("enabled")):
				_set_flag("scanner_on")
				_say(Story.TUTORIAL_STEPS["scanner_on"])
			if _flag("scanner_on") and not _flag("scanned") and _scans > 0:
				_set_flag("scanned")
				_say(Story.TUTORIAL_STEPS["scanned"])
			if _flag("scanned") and not _flag("desk_on") and _desk != null and bool(_desk.get("enabled")):
				_set_flag("desk_on")
				_say(Story.TUTORIAL_STEPS["desk_on"])
			if _flag("studied") and _queue.is_empty():
				_start_chapter(1)
		1:
			if _beacons_done >= 3 and _queue.is_empty():
				_start_chapter(2)
		2:
			if not _flag("pelagia_seen") and _near(_route["pelagia"], 2200.0):
				_set_flag("pelagia_seen")
				_say_batch(Story.PELAGIA_FOUND)
			if _flag("pelagia_done") and _queue.is_empty():
				_start_chapter(3)
		3:
			if _nodes_done >= 3 and _queue.is_empty():
				_start_chapter(4)
		4:
			if not _flag("source_seen") and _near(_route["source"], 2600.0):
				_set_flag("source_seen")
				_say_batch(Story.SOURCE_FOUND)
			if not _flag("source_done") and _desk != null \
					and str(_desk.call("current_subject")) == _subject("source"):
				if float(_desk.call("progress")) >= 0.5 and not _source_mid_said:
					_source_mid_said = true
					_say_batch(Story.SOURCE_MID)
					if _leviathan != null:
						_leviathan.request_manifest()
						_leviathan.force_hunt()
			if _flag("source_done") and _near(_route["extraction"], extraction_radius):
				_finish(true)


func _on_research_started(subject_id: String, _type_id: String, _time: float) -> void:
	if subject_id == _subject("source") and _leviathan != null:
		_leviathan.set_aggression(4)
		if _attention != null:
			_attention.set_attention(maxf(_attention.attention(), 60.0))
		_leviathan.force_hunt()


func _on_research_completed(subject_id: String, _type_id: String, _xp: int, was_new: bool, _data: Dictionary) -> void:
	if was_new:
		_studied += 1
	if _chapter == 0 and not _flag("studied"):
		_set_flag("studied")
		_say(Story.TUTORIAL_STEPS["studied"])
		_say(Story.TUTORIAL_STEPS["keys"])
	for i in range(1, 4):
		if subject_id == _subject("beacon_%d" % i) and was_new:
			_say_batch(Story.BEACON_LOGS[_beacons_done])
			_beacons_done += 1
			if _beacons_done == 2 and _atmosphere != null:
				_atmosphere.fire("phantom")
				if _leviathan != null:
					_leviathan.set_aggression(2)
		if subject_id == _subject("node_%d" % i) and was_new:
			_say_batch(Story.NODE_LOGS[_nodes_done])
			_nodes_done += 1
			if _atmosphere != null:
				_atmosphere.fire("tremor")
	if subject_id == _subject("pelagia"):
		_set_flag("pelagia_done")
		_say_batch(Story.PELAGIA_LOGS)
	if subject_id == _subject("source"):
		_set_flag("source_done")
		_say_batch(Story.SOURCE_DONE)
		if _leviathan != null:
			_leviathan.request_manifest()
			_leviathan.force_hunt()
		if _atmosphere != null:
			_atmosphere.fire("tremor")
	objective_changed.emit()


func _on_hull_destroyed() -> void:
	if _finished:
		return
	_death_timer = 0.0
	GameFeed.notify(get_tree(), GameFeed.PROBLEM, "КОРПУС", "Разгерметизация. Потеря управления.")


func _finish(victory: bool) -> void:
	if _finished:
		return
	_finished = true
	var title := Story.ENDING_TITLE if victory else Story.DEATH_TITLE
	var text := Story.ENDING_TEXT if victory else Story.DEATH_TEXT
	get_tree().call_group("run_end", "show_end", victory, title, text, stats())
	mission_finished.emit(victory)


## ---------------------------------------------------------------- utilities ---

func _place(key: String, kind: String) -> void:
	if _field != null:
		_field.add_story_poi(key, kind, _route[key])


func _subject(key: String) -> String:
	return "poi:%s" % key


func _story_done(key: String) -> bool:
	return _desk != null and bool(_desk.call("is_completed", _subject(key)))


func _near(point: Vector2, radius: float) -> bool:
	return _ship != null and _ship.global_position.distance_to(point) <= radius


func _flag(name: String) -> bool:
	return bool(_flags.get(name, false))


func _set_flag(name: String) -> void:
	_flags[name] = true
	objective_changed.emit()


func _goal(text: String, done: bool) -> String:
	return ("✓ " if done else "") + text


func _say(line: Array) -> void:
	_queue.append(line)


func _say_batch(lines: Array) -> void:
	for line in lines:
		_queue.append(line)


func _tick_comms(delta: float) -> void:
	if _queue.is_empty():
		return
	_queue_wait -= delta
	if _queue_wait > 0.0:
		return
	var line: Array = _queue.pop_front()
	GameFeed.comms(get_tree(), str(line[0]), str(line[1]),
		"hint" if str(line[0]) == Story.HINT else "")
	_queue_wait = line_gap_sec + float(str(line[1]).length()) * 0.02


## Jump straight to a chapter (a test, a debug key).
func debug_jump(index: int) -> void:
	_queue.clear()
	if index >= 1:
		_flags["scanner_on"] = true
		_flags["scanned"] = true
		_flags["desk_on"] = true
		_flags["studied"] = true
	if index >= 2:
		_beacons_done = 3
	if index >= 3:
		_flags["pelagia_seen"] = true
		_flags["pelagia_done"] = true
	if index >= 4:
		_nodes_done = 3
	_start_chapter(clampi(index, 0, Story.CHAPTERS.size() - 1))
