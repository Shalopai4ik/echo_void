extends SceneTree

## Stage 5.2 verification: the research desk.
## Run: godot --headless --path . --script tests/research_system_test.gd

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const MAP_SCENE := preload("res://scenes/world/SpaceMap.tscn")
const SHIPPING_PROFILE := preload("res://assets/research/research_profile.tres")
const SCANNER_PROFILE := preload("res://assets/ship/scanner_profile.tres")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: Node2D
var _hub: ShipSystems
var _scanner: ShipScanner
var _research: ResearchSystem
var _world: FakeWorld

## What the desk said, in order.
var _started: Array = []
var _progressed: Array = []
var _completed: Array = []
var _cancelled: Array = []
var _xp_gained: Array = []
var _available: Array = []
var _refusals: Array = []


## A world that answers the one method the scanner asks for.
class FakeWorld extends Node2D:
	var objects: Array = []
	func objects_near(origin: Vector2, radius: float, limit: int) -> Array:
		var out: Array = []
		for obj in objects:
			if obj is Node2D and obj.global_position.distance_to(origin) <= radius:
				out.append(obj)
		out.sort_custom(func(a, b):
			return a.global_position.distance_to(origin) < b.global_position.distance_to(origin))
		return out.slice(0, limit)


## A scannable object: a Node2D in a group, with population meta and info.
class FakeObject extends Node2D:
	var object_kind: String = ""
	var object_info: Dictionary = {}

	func world_object_kind() -> String:
		return object_kind

	func world_object_info() -> Dictionary:
		return object_info.duplicate(true)


func make_object(name: String, position: Vector2, population: String,
		kind: String = "", groups: Array = [], info: Dictionary = {}) -> Node2D:
	var obj := FakeObject.new()
	obj.name = name
	_root.add_child(obj)
	obj.global_position = position
	obj.set_meta("population", population)
	obj.set_meta("chunk_id", "test_chunk")
	obj.set_meta("item_id", name)
	for g in groups:
		obj.add_to_group(g)
	obj.object_kind = kind
	obj.object_info = info
	return obj


func _check(desc: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("PASS: ", desc)
	else:
		_failed += 1
		print("FAIL: ", desc)


func _fail(desc: String) -> void:
	_failed += 1
	_checks += 1
	print("FAIL: ", desc)


## ---------------------------------------------------------------- setup ---

func _initialize() -> void:
	_root = Node2D.new()
	get_root().add_child(_root)

	# Build the ship with systems hub.
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	_hub = _ship.get_node("Systems")
	assert(_hub != null, "Ship/Systems hub missing")

	# Build a fake world in the "world_field" group so the scanner finds it.
	_world = FakeWorld.new()
	_world.add_to_group("world_field")
	_root.add_child(_world)

	# Mount the scanner.
	_scanner = ShipScanner.new()
	_scanner.name = "Scanner"
	_scanner.component_id = "scanner"
	_scanner.title = "Survey Scanner"
	_scanner.profile = SCANNER_PROFILE.duplicate(true)
	_scanner.nominal_power_draw = 6.0
	_scanner.starts_enabled = false
	_ship.get_node("Systems").add_child(_scanner)

	# Mount the research desk.
	_research = ResearchSystem.new()
	_research.component_id = "research"
	_research.title = "Research Desk"
	_research.profile = SHIPPING_PROFILE.duplicate()
	_research.nominal_power_draw = 4.0
	_research.starts_enabled = false

	# Wire signals.
	_scanner.scan_completed.connect(_on_scan_completed)
	_research.research_started.connect(func(s, t, time):
		_started.append({"subject": s, "type": t, "time": time})
	)
	_research.research_progress.connect(func(s, p):
		_progressed.append({"subject": s, "progress": p})
	)
	_research.research_completed.connect(func(s, t, xp, new, data):
		_completed.append({"subject": s, "type": t, "xp": xp, "new": new, "data": data})
	)
	_research.research_cancelled.connect(func(s, reason):
		_cancelled.append({"subject": s, "reason": reason})
	)
	_research.xp_gained.connect(func(amount, total):
		_xp_gained.append({"amount": amount, "total": total})
	)
	_research.research_available.connect(func(contact):
		_available.append(contact.duplicate(true))
	)


	# Enable both devices so they can operate.
	_scanner.set_enabled(true)
	_scanner.set_enabled(true)
	_research.set_enabled(true)

	# Phase A: the desk exists and is idle.
	print("=== Phase A: initial state ===")
	_check("desk is not researching", not _research.is_researching())
	_check("desk XP is zero", _research.get_xp() == 0)
	_check("no subjects known", _research.status()["research_subjects"] == 0)

	# Phase B: a contact the profile doesn't know cannot be researched.
	print("=== Phase B: unknown contact ===")
	var unknown_contact := {
		"id": "test:unknown", "source": "object", "kind": "totally_unknown",
		"signature": "totally_unknown_sig", "identified": false, "title": "",
		"position": Vector2(100, 0), "distance": 100.0, "bearing": 0.0,
		"strength": 0.5, "population": "", "info": {}, "at": 0.0,
	}
	_check("cannot research unknown contact", not _research.can_research(unknown_contact))
	_check("start_refused for unknown", not _research.start_research(unknown_contact))
	_check("refusal reason is unknown_type", _research.refuse_reason() == "unknown_type")

	# Phase C: a known contact can be researched.
	print("=== Phase C: known contact ===")
	var asteroid := make_object("rock1", Vector2(500, 0), "asteroids",
		"asteroid", ["asteroid"], {"px_scale": 1.5, "extent": 120.0})
	_world.objects.append(asteroid)
	var contact := {
		"id": "test_chunk:rock1", "source": "object", "kind": "asteroid",
		"signature": "asteroid", "identified": true, "title": "Asteroid",
		"position": Vector2(500, 0), "distance": 500.0, "bearing": 0.0,
		"strength": 0.8, "population": "asteroids",
		"info": {"px_scale": 1.5, "extent": 120.0}, "at": 0.0,
	}
	_check("can research asteroid contact", _research.can_research(contact))
	_check("start_research returns true", _research.start_research(contact))
	_check("desk is researching", _research.is_researching())
	_check("research_started emitted", _started.size() == 1)
	_check("started subject id", _started[0]["subject"] == "test_chunk:rock1")
	_check("started type id", _started[0]["type"] == "asteroid")
	_check("progress is zero at start", _research.progress() == 0.0)

	# Phase D: research progresses over time.
	print("=== Phase D: progress over time ===")
	for i in range(100):
		_research._physics_process(0.1)
	_check("progress is about 0.5", _research.progress() > 0.4 and _research.progress() < 0.6)
	_check("still researching", _research.is_researching())

	# Phase E: complete the research.
	print("=== Phase E: completion ===")
	for i in range(120):
		_research._physics_process(0.1)
	_check("desk is not researching", not _research.is_researching())
	_check("research_completed emitted", _completed.size() == 1)
	_check("completed subject", _completed[0]["subject"] == "test_chunk:rock1")
	_check("completed type", _completed[0]["type"] == "asteroid")
	_check("XP awarded", _completed[0]["xp"] == 30)
	_check("was_new is true", _completed[0]["new"] == true)
	_check("XP gained signal", _xp_gained.size() == 1)
	_check("XP gained amount", _xp_gained[0]["amount"] == 30)
	_check("total XP is 30", _research.get_xp() == 30)
	_check("subject is completed", _research.is_completed("test_chunk:rock1"))
	_check("subject progress is 1.0", _research.subject_progress("test_chunk:rock1") == 1.0)

	# Phase F: repeat research on same subject yields no XP.
	print("=== Phase F: no double XP ===")
	_check("cannot restart completed subject", not _research.start_research(contact))
	_check("refusal is already_done", _research.refuse_reason() == "already_done")
	_check("XP still 30", _research.get_xp() == 30)
	_check("no additional xp_gained", _xp_gained.size() == 1)

	# Phase G: cancel and resume.
	print("=== Phase G: cancel and resume ===")
	var debris := make_object("debris1", Vector2(300, 0), "debris",
		"debris", ["debris"], {"px_scale": 0.8, "extent": 60.0})
	_world.objects.append(debris)
	var debris_contact := {
		"id": "test_chunk:debris1", "source": "object", "kind": "debris",
		"signature": "debris", "identified": true, "title": "Debris",
		"position": Vector2(300, 0), "distance": 300.0, "bearing": 0.0,
		"strength": 0.7, "population": "debris",
		"info": {"px_scale": 0.8, "extent": 60.0}, "at": 0.0,
	}
	_check("can research debris", _research.start_research(debris_contact))
	_check("researching debris", _research.is_researching())
	for i in range(50):
		_research._physics_process(0.1)
	_check("progress about 0.33", _research.progress() > 0.3 and _research.progress() < 0.4)
	_research.cancel_research("aborted")
	_check("not researching after cancel", not _research.is_researching())
	_check("cancelled emitted", _cancelled.size() == 1)
	_check("cancelled subject", _cancelled[0]["subject"] == "test_chunk:debris1")
	_check("progress saved", _research.subject_progress("test_chunk:debris1") > 0.0)
	_check("progress saved about 0.33", _research.subject_progress("test_chunk:debris1") > 0.3 and _research.subject_progress("test_chunk:debris1") < 0.4)
	_check("can resume debris", _research.start_research(debris_contact))
	_check("researching again", _research.is_researching())
	for i in range(150):
		_research._physics_process(0.1)
	_check("debris completed", _research.is_completed("test_chunk:debris1"))
	_check("debris XP awarded", _completed.size() == 2)
	_check("debris XP is 20", _completed[1]["xp"] == 20)
	_check("total XP is 50", _research.get_xp() == 50)



	# Phase H: unknown signal / anomaly (phantom) contact.
	print("=== Phase H: phantom contact ===")
	var phantom_contact := {
		"id": "sig:10,20", "source": "signal", "kind": "anomaly",
		"signature": "resonance", "identified": false, "title": "",
		"position": Vector2(15000, 0), "distance": 15000.0, "bearing": 0.0,
		"strength": 0.3, "population": "", "info": {}, "at": 0.0,
	}
	_check("can research phantom", _research.can_research(phantom_contact))
	_check("start_research phantom", _research.start_research(phantom_contact))
	_check("phantom type is resonance", _started[_started.size()-1]["type"] == "resonance")
	for i in range(1300):
		_research._physics_process(0.1)
	_check("phantom completed", _research.is_completed("sig:10,20"))
	_check("phantom XP is 300", _completed[_completed.size()-1]["xp"] == 300)
	_check("total XP is 350", _research.get_xp() == 350)
	_check("rare anomaly paid more", _completed[_completed.size()-1]["xp"] > _completed[0]["xp"])

	# Phase I: busy refusal - can't start second research while one is running.
	print("=== Phase I: busy refusal ===")
	var rock2 := make_object("rock2", Vector2(400, 0), "asteroids",
		"asteroid", ["asteroid"], {"px_scale": 1.2, "extent": 100.0})
	_world.objects.append(rock2)
	var contact2 := {
		"id": "test_chunk:rock2", "source": "object", "kind": "asteroid",
		"signature": "asteroid", "identified": true, "title": "Asteroid",
		"position": Vector2(400, 0), "distance": 400.0, "bearing": 0.0,
		"strength": 0.8, "population": "asteroids",
		"info": {"px_scale": 1.2, "extent": 100.0}, "at": 0.0,
	}
	_check("can start new research", _research.start_research(contact2))
	_check("busy on second start", not _research.start_research(contact2))
	_check("refusal is busy", _research.refuse_reason() == "busy")
	_research.cancel_research("aborted")

	# Phase J: save and load.
	print("=== Phase J: save/load ===")
	_check("has subjects", _research.status()["research_subjects"] == 4)
	var saved := _research.to_dict()
	_check("saved has xp", saved.has("xp"))
	_check("saved xp is 350", int(saved["xp"]) == 350)
	_check("saved has progress", saved.has("progress"))

	var desk2 = ResearchSystem.new()
	desk2.component_id = "research2"
	desk2.profile = SHIPPING_PROFILE.duplicate()
	_root.add_child(desk2)
	var loaded := desk2.from_dict(saved)
	_check("load returned true", loaded == true)
	_check("loaded XP matches", desk2.get_xp() == 350)
	_check("loaded knows completed subjects", desk2.is_completed("test_chunk:rock1"))
	_check("loaded knows progress", desk2.subject_progress("test_chunk:rock1") == 1.0)
	_check("cannot re-research completed", not desk2.start_research(contact))

	# Phase K: scanner integration - research_available emitted on scan.
	print("=== Phase K: scanner integration ===")
	_available.clear()
	var rock3 := make_object("rock3", Vector2(200, 0), "asteroids",
		"asteroid", ["asteroid"], {"px_scale": 1.0, "extent": 90.0})
	_world.objects.append(rock3)
	_research._on_scan_completed([{
		"id": "test_chunk:rock3", "source": "object", "kind": "asteroid",
		"signature": "asteroid", "identified": true, "title": "Asteroid",
		"position": Vector2(200, 0), "distance": 200.0, "bearing": 0.0,
		"strength": 0.9, "population": "asteroids",
		"info": {"px_scale": 1.0, "extent": 90.0}, "at": 0.0,
	}])
	_check("research_available emitted", _available.size() == 1)
	_check("available subject", _available[0]["id"] == "test_chunk:rock3")

	# Phase L: shutdown.
	print("=== Phase L: teardown ===")
	_world.objects.clear()
	# The desk was built in code and never entered the tree, so the tree will
	# not free it for us. It holds the profile resource, so leaving it alive
	# leaks the desk and every type in the profile.
	if is_instance_valid(_research):
		_research.free()
	_research = null
	_hub = null
	_scanner = null
	_ship = null
	_world = null
	get_root().remove_child(_root)
	_root.free()

	print("")
	var result_text := "=== Results: %d checks, %d failed ===" % [_checks, _failed]
	print(result_text)
	if _failed == 0:
		print("RESULT: ALL PASS")
	else:
		print("RESULT: FAILURE")
	quit(1 if _failed > 0 else 0)


## Forward physics to the desk.
func _physics_process(delta: float) -> bool:
	return true


func _on_scan_completed(contacts: Array) -> void:
	_research._on_scan_completed(contacts)
