extends SceneTree

## Stage 5.1 verification: the survey scanner.
## Run: godot --headless --path . --script tests/scanner_test.gd
##
## The ship's control layer (4.1-4.5) already had a mount, a switch, a power grant
## and a damage ledger; what it did not have was a device that actually *does*
## something. This suite holds the scanner to the brief:
##
##   A. a sweep finds what is inside the disc and nothing outside it;
##   B. distance decides what is reported and what is named - a derelict is an
##      anomaly from afar and itself up close, and an unidentified contact carries
##      no title and no numbers;
##   C. an object the profile does not answer for is never reported;
##   D. the range knob moves the disc, and a damaged dish reaches less;
##   E. a second order during a sweep is refused and spends nothing;
##   F. the pulse is paid for out of the ship's reserve, and a tank that cannot pay
##      refuses the sweep without spending;
##   G. contacts arrive across the sweep, not in one frame, and the completion list
##      matches the ones that arrived;
##   H. results reach the ship's bus and the device's own signals with the same ids;
##   I. the switch and a brownout cancel a sweep in flight;
##   J. the upgrade seams (range multiplier, sensitivity) change the picture;
##   K. phantom signatures are deterministic, never named, and distinguishable;
##   L. the real world field answers `objects_near()` and a sweep in flight finds
##      contacts of more than one kind;
##   M. teardown.
##
## The synthetic world in phase A is deliberate: the real field's content is a hash
## of the seed, so a threshold can only be proved against objects placed at known
## distances. Phase L then proves the real field answers the same question.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const MAP_SCENE := preload("res://scenes/world/SpaceMap.tscn")
const SHIPPING_PROFILE := preload("res://assets/ship/scanner_profile.tres")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: ShipController
var _hub: ShipSystems
var _scanner: ShipScanner
var _world: FakeWorld
var _base: ShipSystemsParameters
## What the device said, in order. The suite reads these instead of building a new
## listener per phase, so a phase cannot leak one into the next.
var _refusals: Array = []
var _heard: Array = []
var _completed: Array = []
var _cancelled: Array = []
var _events: Array = []


## A world that answers the one method the scanner asks for, with the objects the
## test placed in it. It mirrors `EchoWorldField.objects_near()`: inside the disc,
## nearest first, at most `limit`.
class FakeWorld extends Node2D:
	var asked := 0
	var last_radius := 0.0
	var last_limit := 0

	func _ready() -> void:
		add_to_group("world_field")

	func objects_near(center: Vector2, radius: float, limit := 0) -> Array[Node2D]:
		asked += 1
		last_radius = radius
		last_limit = limit
		var found: Array = []
		for child in get_children():
			var node := child as Node2D
			if node == null:
				continue
			var distance := node.global_position.distance_to(center)
			if distance <= radius:
				found.append({"node": node, "d": distance})
		found.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
		var out: Array[Node2D] = []
		var take := found.size() if limit <= 0 else mini(limit, found.size())
		for i in take:
			out.append(found[i]["node"])
		return out

	func get_seed() -> int:
		return 20261102


## A thing in the world that introduces itself the way `StageRock` does. Nothing
## about it is a rock: the scanner only reads the two methods and the group.
class FakeBody extends Node2D:
	var title := "asteroid_04"
	var population := "asteroids"
	var info := {"px_scale": 2.0, "extent": 40.0, "mass": 8.0, "inside": "secret"}
	var object_kind := "asteroid"

	func _ready() -> void:
		set_meta("population", population)
		if object_kind == "asteroid":
			add_to_group("asteroid")
		elif object_kind == "debris":
			add_to_group("debris")

	func world_object_kind() -> String:
		return object_kind

	func world_object_info() -> Dictionary:
		return {"title": title, "shape": "04"}.merged(info, true)


## A decorative silhouette: no interface, no group, only a population label. The
## scanner must leave it alone, which is what keeps background clutter out of the
## contact list.
class FakeScenery extends Node2D:
	func _ready() -> void:
		set_meta("population", "shadows")


func _initialize() -> void:
	call_deferred("_run")


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


# ------------------------------------------------------------------ fixtures ----

## The shipping profile with the sweep shortened and, by default, the phantom
## signatures removed: a threshold can only be proved against objects the test
## itself placed, and a phantom is by definition one nobody placed.
func _profile(seconds := 0.5, keep_phantoms := false) -> ScannerProfile:
	var p: ScannerProfile = SHIPPING_PROFILE.duplicate(true)
	p.sweep_seconds = seconds
	if keep_phantoms:
		return p
	var kept: Array[ScanSignature] = []
	for signature in p.signatures:
		if signature != null and not signature.phantom:
			kept.append(signature)
	p.signatures = kept
	return p


func _mount_scanner() -> ShipScanner:
	var scanner := ShipScanner.new()
	scanner.name = "Scanner"
	scanner.component_id = "scanner"
	scanner.title = "Scanner"
	scanner.profile = _profile()
	scanner.starts_enabled = true
	# A real appetite, so the bus rules in phase I can actually apply to it. A
	# passive device is never starved, and a scanner that cannot lose its power is a
	# scanner whose brownout behaviour cannot be proved.
	scanner.nominal_power_draw = 5.0
	_hub.add_child(scanner)
	return scanner


## A tank with no regeneration, so every energy assertion is exact - the same
## fixture the equipment suite uses.
func _tuning(capacity := 400.0, reactor := 240.0) -> ShipSystemsParameters:
	var p: ShipSystemsParameters = _base.duplicate(true)
	p.reactor_output = reactor
	p.energy_capacity = capacity
	p.energy_recharge_rate = 0.0
	p.offline_integrity = 0.15
	p.damaged_integrity = 0.6
	p.damaged_efficiency = 0.5
	return p


func _clear_world() -> void:
	for child in _world.get_children():
		_world.remove_child(child)
		child.free()


func _rock(at: Vector2, title := "asteroid_04") -> FakeBody:
	return _fake(at, "asteroids", "asteroid", title)


func _debris(at: Vector2) -> FakeBody:
	return _fake(at, "debris", "debris", "debris_02")


func _fake(at: Vector2, population: String, kind: String, title: String) -> FakeBody:
	var body := FakeBody.new()
	body.population = population
	body.object_kind = kind
	body.title = title
	body.position = at
	_world.add_child(body)
	return body


## Run one sweep to the end and hand back its contacts. A guard stops a broken
## sweep from hanging the suite: a sweep is a few hundred physics frames at most.
func _sweep() -> Array:
	if not _scanner.start_scan():
		return []
	var guard := 0
	while _scanner.is_scanning() and guard < 900:
		guard += 1
		await physics_frame
	return _scanner.last_contacts()


func _ids(contacts: Array) -> Array:
	var out: Array = []
	for contact in contacts:
		out.append(String(contact.get("id", "")))
	return out


func _kinds(contacts: Array) -> Array:
	var out: Array = []
	for contact in contacts:
		out.append(String(contact.get("kind", "")))
	return out


func _count_source(contacts: Array, source: String) -> int:
	var n := 0
	for contact in contacts:
		if String(contact.get("source", "")) == source:
			n += 1
	return n


func _reset_hearing() -> void:
	_refusals.clear()
	_heard.clear()
	_completed.clear()
	_cancelled.clear()
	_events.clear()


func _on_refused(reason: String) -> void:
	_refusals.append(reason)


func _on_contact(contact: Dictionary) -> void:
	_heard.append(contact)


func _on_completed(contacts: Array) -> void:
	_completed.append(contacts)


func _on_cancelled(reason: String) -> void:
	_cancelled.append(reason)


func _on_event(event: ShipSystemEvent) -> void:
	_events.append(event)


## The one bus event with this topic, or an empty dictionary.
func _event_with(topic: String) -> Dictionary:
	for event in _events:
		if String(event.data.get("topic", "")) == topic:
			return event.data
	return {}


## Press and release the scanner's key the way a keyboard would, so the phase proves
## the binding in `project.godot` reaches the device rather than only its script API.
func _press_scan() -> void:
	_key(KEY_R, true)


func _release_scan() -> void:
	_key(KEY_R, false)


func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


# ---------------------------------------------------------------------- setup ---

func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	_world = FakeWorld.new()
	_world.name = "World"
	_root.add_child(_world)
	_ship = SHIP_SCENE.instantiate()
	_ship.global_position = Vector2.ZERO
	_root.add_child(_ship)
	_hub = _ship.get_node_or_null("Systems") as ShipSystems
	if _hub == null:
		print("RESULT: FAILED  Ship.tscn has no Systems node")
		quit(2)
		return
	_base = _hub.parameters
	_hub.set_parameters(_tuning())
	_hub.set_energy(400.0)
	# The reserve is not allowed to tick during this suite: every energy assertion
	# compares two exact levels, and a clock that spends 5 units a second would make
	# the arithmetic a race. The same rule `ship_equipment_test` follows.
	_hub.clock.set_physics_process(false)
	_scanner = _mount_scanner()
	await _steps(2)
	_scanner.scan_refused.connect(_on_refused)
	_scanner.contact_found.connect(_on_contact)
	_scanner.scan_completed.connect(_on_completed)
	_scanner.scan_cancelled.connect(_on_cancelled)
	_hub.system_event.connect(_on_event)
	_ok("the scanner mounts with no change to the hub",
		_hub.has_component("scanner") and _scanner.systems == _hub,
		", ".join(_hub.component_ids()))
	_ok("its own state is derived like every other device",
		_scanner.state == ShipSystemState.Value.NOMINAL, _scanner.status_line())
	_ok("it asks the world for its answers, not the tree",
		_scanner.world() == _world)

	await _test_disc()
	await _test_naming()
	await _test_silence()
	await _test_range()
	await _test_busy()
	await _test_energy()
	await _test_pacing()
	await _test_delivery()
	await _test_interruption()
	await _test_upgrades()
	await _test_phantoms()
	await _test_real_world()
	await _teardown()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


# ------------------------------------------------------------ A. the disc ------

## What is inside the disc is reported, what is outside is not, and the list comes
## back nearest first - a pilot reads it from the hull outwards.
func _test_disc() -> void:
	print("-- the disc")
	_clear_world()
	_rock(Vector2(0.0, -200.0))
	_rock(Vector2(0.0, 900.0))
	_rock(Vector2(0.0, 1200.0))
	var scenery := FakeScenery.new()
	scenery.position = Vector2(80.0, 0.0)
	_world.add_child(scenery)

	var contacts: Array = await _sweep()
	_ok("a sweep completes and reports", not _scanner.is_scanning(), "%.2f" % _scanner.progress())
	_ok("only what is inside the disc is reported", contacts.size() == 2,
		"%d contacts, radius %.0f" % [contacts.size(), _scanner.range_now()])
	if contacts.size() < 2:
		return
	_ok("the list is nearest first",
		float(contacts[0].distance) < float(contacts[1].distance),
		"%.0f then %.0f px" % [float(contacts[0].distance), float(contacts[1].distance)])
	_ok("the nearest one is the stone at 200 px",
		is_equal_approx(float(contacts[0].distance), 200.0),
		"%.0f px" % float(contacts[0].distance))
	_ok("both are read as asteroids", _kinds(contacts) == ["asteroid", "asteroid"],
		str(_kinds(contacts)))
	_ok("each contact has its own id",
		String(contacts[0].id).begins_with("obj:") and String(contacts[0].id) != String(contacts[1].id),
		String(contacts[0].id))
	_ok("a decorative silhouette is not a contact",
		not _ids(contacts).has("obj:%d" % scenery.get_instance_id()))
	var first: Dictionary = contacts[0]
	_ok("a contact carries position, bearing, distance and strength",
		first.has("position") and first.has("bearing") and first.has("distance")
			and first.has("strength") and float(first.strength) > 0.5,
		"strength %.2f at %.0f px" % [float(first.strength), float(first.distance)])


# ---------------------------------------------------------- B. what is named ---

## The same object tells a different story at a different distance, and an
## unidentified contact is not allowed to leak a name or a number.
func _test_naming() -> void:
	print("-- what is named")
	_clear_world()
	var wreck := _fake(Vector2(900.0, 0.0), "wrecks", "unknown_object", "")
	wreck.info = {"crew": 0, "cargo": ["sealed"]}
	var far: Array = await _sweep()
	_ok("a derelict is reported from the far side of the disc", far.size() == 1,
		"%d contacts" % far.size())
	if far.size() == 1:
		var contact: Dictionary = far[0]
		_ok("but it is only an anomaly at that range",
			String(contact.kind) == "anomaly" and not bool(contact.identified),
			"%s at %.0f px, strength %.2f" % [contact.kind, float(contact.distance),
				float(contact.strength)])
		_ok("and it is not named", String(contact.title).is_empty(), "\"%s\"" % contact.title)
		_ok("and it reveals nothing about itself", (contact.info as Dictionary).is_empty(),
			str(contact.info))

	wreck.position = Vector2(300.0, 0.0)
	var near: Array = await _sweep()
	_ok("closer in, the same object is named", near.size() == 1
		and String(near[0].kind) == "derelict" and bool(near[0].identified),
		"%d contacts" % near.size())
	if near.size() == 1:
		_ok("the name is the profile's, not the object's",
			String(near[0].title) == "derelict", "\"%s\"" % near[0].title)
		_ok("a derelict still reveals nothing it was not told to",
			(near[0].info as Dictionary).is_empty(), str(near[0].info))

	_clear_world()
	_debris(Vector2(200.0, 0.0))
	var junk: Array = await _sweep()
	_ok("debris is named as debris", junk.size() == 1 and String(junk[0].kind) == "debris",
		str(_kinds(junk)))
	if junk.size() == 1:
		var info: Dictionary = junk[0].info
		_ok("a survey learns its size", info.has("px_scale") and info.has("extent"),
			str(info))
		_ok("but not the numbers the signature did not open",
			not info.has("inside") and not info.has("mass"), str(info))


# ------------------------------------------------------------- C. silence ------

## Nothing the profile answers for means no contacts - an empty sweep is a result,
## not a failure, and it still completes and pays for itself.
func _test_silence() -> void:
	print("-- silence")
	_clear_world()
	var scenery := FakeScenery.new()
	_world.add_child(scenery)
	var charge := _hub.energy_charge()
	var contacts: Array = await _sweep()
	_ok("an empty disc reports no contacts", contacts.is_empty(), "%d" % contacts.size())
	_ok("and the sweep still finished", not _scanner.is_scanning()
		and is_equal_approx(_scanner.progress(), 0.0))
	_ok("and still cost its pulse",
		is_equal_approx(_hub.energy_charge(), charge - 12.0),
		"%.1f -> %.1f" % [charge, _hub.energy_charge()])


# --------------------------------------------------------------- D. range ------

## The radius is a number, not a constant: the upgrade seam moves it, damage moves
## it the other way, and the sweep never reports an object it could not reach.
func _test_range() -> void:
	print("-- range")
	_clear_world()
	_fake(Vector2(900.0, 0.0), "wrecks", "unknown_object", "")
	_ok("the disc is the profile's radius",
		is_equal_approx(_scanner.range_now(), 1100.0), "%.0f px" % _scanner.range_now())
	_scanner.set_range_multiplier(0.5)
	_ok("the upgrade seam scales the disc",
		is_equal_approx(_scanner.range_now(), 550.0), "%.0f px" % _scanner.range_now())
	var short: Array = await _sweep()
	_ok("a shorter disc finds nothing at 900 px", short.is_empty(),
		"%d contacts" % short.size())
	_scanner.set_range_multiplier(1.0)

	_hub.apply_damage("scanner", 0.5)
	_ok("a hurt dish sweeps a smaller disc",
		_scanner.range_now() < 1100.0 and _scanner.range_now() > 300.0,
		"%.0f px" % _scanner.range_now())
	_ok("and takes longer over it", _scanner.sweep_seconds_now() > 0.5,
		"%.2f s" % _scanner.sweep_seconds_now())
	var hurt: Array = await _sweep()
	_ok("a hurt dish cannot reach what it used to", hurt.is_empty(),
		"%d contacts at %.0f px" % [hurt.size(), _scanner.range_now()])
	_ok("damage does not stop it working entirely",
		_scanner.state == ShipSystemState.Value.DAMAGED, _scanner.status_line())

	_hub.repair("scanner", 1.0)
	_ok("repair restores the disc and the timing",
		is_equal_approx(_scanner.range_now(), 1100.0)
			and is_equal_approx(_scanner.sweep_seconds_now(), 0.5),
		"%.0f px  %.2f s" % [_scanner.range_now(), _scanner.sweep_seconds_now()])


# --------------------------------------------------------------- E. busy -------

## One sweep at a time, and the order can come from the pilot's key as well as from
## a script. The second order is refused by name, costs nothing, and the first sweep
## is not disturbed by it.
func _test_busy() -> void:
	print("-- one sweep at a time")
	_clear_world()
	_rock(Vector2(150.0, 0.0))
	_reset_hearing()
	_press_scan()
	await process_frame
	await physics_frame
	_ok("the scan key orders a sweep", _scanner.is_scanning(), _scanner.status_line())
	_release_scan()
	_scanner.cancel_scan("test")
	_reset_hearing()

	var charge := _hub.energy_charge()
	_ok("an order starts a sweep", _scanner.start_scan())
	_ok("a second order during a sweep is refused",
		not _scanner.start_scan() and _scanner.refuse_reason() == "busy",
		_scanner.refuse_reason())
	_ok("the refusal is announced once", _refusals.size() == 1
		and String(_refusals[0]) == "busy", str(_refusals))
	_ok("and the refusal spent nothing",
		is_equal_approx(_hub.energy_charge(), charge - 12.0),
		"%.1f -> %.1f" % [charge, _hub.energy_charge()])
	while _scanner.is_scanning():
		await physics_frame
	_ok("the first sweep still completes", _scanner.last_contacts().size() == 1,
		"%d contacts" % _scanner.last_contacts().size())


# -------------------------------------------------------------- F. energy ------

## The pulse is paid for out of the ship's own reserve, through the one door the
## energy system offers for a pulse, and a tank that cannot pay refuses the order
## without spending a unit.
func _test_energy() -> void:
	print("-- energy")
	_clear_world()
	_rock(Vector2(160.0, 0.0))
	_ok("a sweep costs what the profile says",
		is_equal_approx(_scanner.sweep_cost_now(), 12.0), "%.1f units" % _scanner.sweep_cost_now())
	var charge := _hub.energy_charge()
	_reset_hearing()
	await _sweep()
	_ok("the reserve paid for the pulse",
		is_equal_approx(_hub.energy_charge(), charge - 12.0),
		"%.1f -> %.1f" % [charge, _hub.energy_charge()])
	_ok("a paid pulse is not reported as a refusal", _event_with("energy_refused").is_empty())

	_hub.set_energy(4.0)
	_reset_hearing()
	var poor: bool = _scanner.start_scan()
	_ok("a reserve that cannot pay refuses the sweep",
		not poor and _scanner.refuse_reason() == "energy", _scanner.refuse_reason())
	_ok("the refusal is announced", _refusals.size() == 1
		and String(_refusals[0]) == "energy", str(_refusals))
	_ok("and nothing was spent", is_equal_approx(_hub.energy_charge(), 4.0),
		"%.1f units" % _hub.energy_charge())
	_ok("and no sweep is running", not _scanner.is_scanning())
	_ok("the ship's own bus reports the dry reserve",
		is_equal_approx(float(_event_with("energy_refused").get("cost", -1.0)), 12.0),
		str(_event_with("energy_refused")))

	_hub.set_energy(400.0)


# -------------------------------------------------------------- G. pacing ------

## A sweep hands its picture out across its own duration instead of answering in the
## frame it was ordered. That is what makes it something the pilot waits on, and it
## is also what keeps the per-frame cost of a scan at nothing but arithmetic.
func _test_pacing() -> void:
	print("-- pacing")
	_scanner.set_profile(_profile(1.2))
	_clear_world()
	for i in 4:
		_rock(Vector2(150.0 + 150.0 * float(i), 0.0))
	_reset_hearing()
	_ok("a longer sweep is what the profile says",
		is_equal_approx(_scanner.sweep_seconds_now(), 1.2),
		"%.2f s" % _scanner.sweep_seconds_now())
	_ok("the order starts", _scanner.start_scan())
	_ok("nothing arrives in the frame the order was given",
		_heard.is_empty(), "%d heard" % _heard.size())
	await _steps(20)
	var early := _heard.size()
	_ok("contacts arrive while the sweep runs", early >= 1 and early < 4,
		"%d of 4 after 20 frames, progress %.2f" % [early, _scanner.progress()])
	_ok("progress reports how far along it is",
		_scanner.progress() > 0.2 and _scanner.progress() < 0.45,
		"%.2f" % _scanner.progress())
	await _steps(20)
	_ok("and they keep arriving", _heard.size() > early and _heard.size() < 4
		or _heard.size() == 4, "%d of 4 after 40 frames" % _heard.size())
	while _scanner.is_scanning():
		await physics_frame
	_ok("the sweep finishes on its own clock", not _scanner.is_scanning())
	_ok("every contact arrived exactly once", _heard.size() == 4, "%d heard" % _heard.size())
	_ok("and the completion list holds the same four",
		_completed.size() == 1 and (_completed[0] as Array).size() == 4,
		"%d completions" % _completed.size())
	_ok("a finished sweep reports progress zero", is_equal_approx(_scanner.progress(), 0.0))


# ------------------------------------------------------------ H. delivery ------

## Two doors, one picture: the device's signals and the ship's own bus carry the same
## contacts with the same ids, so a research stage, a panel and a log all read one
## answer.
func _test_delivery() -> void:
	print("-- delivery")
	_scanner.set_profile(_profile(0.5))
	_clear_world()
	_rock(Vector2(120.0, 0.0))
	_debris(Vector2(260.0, 0.0))
	_reset_hearing()
	var contacts: Array = await _sweep()
	_ok("the contacts arrived one at a time", _heard.size() == contacts.size(),
		"%d heard, %d reported" % [_heard.size(), contacts.size()])
	_ok("the stream and the report agree on every id",
		_ids(_heard) == _ids(contacts), str(_ids(contacts)))
	var finished := _event_with("scan_completed")
	_ok("the ship's bus carries the finished sweep", not finished.is_empty(),
		str(_events.size()) + " events")
	_ok("with the same number of contacts",
		int(finished.get("count", -1)) == contacts.size(),
		"%d on the bus, %d in the device" % [int(finished.get("count", -1)), contacts.size()])
	var carried: Array = finished.get("contacts", [])
	_ok("and the same ids", _ids(carried) == _ids(contacts), str(_ids(carried)))
	_ok("a contact carries the sweep it belongs to",
		not contacts.is_empty() and float(contacts[0].get("at", -1.0)) >= 0.0)
	var status := _scanner.status()
	_ok("the device reports the sweep through the same status shape",
		status.has("scan_range") and status.has("scan_progress")
			and int(status.get("scan_contacts", -1)) == contacts.size(),
		str(status.get("scan_contacts")))
	_ok("and the hub serves it without knowing the device",
		_hub.equipment_status("scanner").has("scan_range"))


# -------------------------------------------------------- I. interruptions ------

## A sweep is hardware: switching the sensor off or losing its power stops it, keeps
## what it had already found, and leaves it ready for the next order. A starved bus
## refuses an order outright rather than running a sweep on a dead sensor.
func _test_interruption() -> void:
	print("-- interruptions")
	_scanner.set_profile(_profile(2.0))
	_clear_world()
	_rock(Vector2(100.0, 0.0))
	_rock(Vector2(200.0, 0.0))
	_rock(Vector2(300.0, 0.0))
	_reset_hearing()
	_ok("a long sweep starts", _scanner.start_scan())
	await _steps(10)
	_hub.set_enabled("scanner", false)
	_ok("switching the sensor off ends the sweep",
		not _scanner.is_scanning() and _cancelled == ["switched_off"], str(_cancelled))
	_ok("the sweep did not report itself as completed", _completed.is_empty())
	_ok("the contacts it had reached are kept",
		_scanner.last_contacts().size() == _heard.size(),
		"%d kept, %d heard" % [_scanner.last_contacts().size(), _heard.size()])
	_ok("the sensor is off, not broken",
		_scanner.state == ShipSystemState.Value.OFFLINE and _scanner.can_start())
	_ok("a cold sensor is lit by the order itself",
		_scanner.start_scan() and _scanner.enabled, _scanner.status_line())
	_scanner.cancel_scan("test")

	_ok("the switch goes back on", _hub.set_enabled("scanner", true))
	_reset_hearing()
	_hub.set_parameters(_tuning(400.0, 0.0))
	_ok("a starved bus leaves the sensor unpowered",
		_scanner.state == ShipSystemState.Value.OFFLINE, _scanner.status_line())
	var charge := _hub.energy_charge()
	_ok("an unpowered sensor refuses the order", not _scanner.start_scan()
		and _scanner.refuse_reason() == "unpowered", _scanner.refuse_reason())
	_ok("and spent nothing on the refusal", is_equal_approx(_hub.energy_charge(), charge),
		"%.1f units" % _hub.energy_charge())

	_hub.set_parameters(_tuning())
	_hub.set_energy(400.0)
	_ok("with the reactor back the sensor is nominal again",
		_scanner.state == ShipSystemState.Value.NOMINAL, _scanner.status_line())


# ---------------------------------------------------------- J. the upgrades -----

## The two seams a later upgrade system turns. Neither needs a new device: a better
## dish is a multiplier on the radius, a better receiver a multiplier on the return.
func _test_upgrades() -> void:
	print("-- upgrade seams")
	_scanner.set_profile(_profile(0.5))
	_clear_world()
	_rock(Vector2(1500.0, 0.0))
	_ok("at stock range the far stone is outside", (await _sweep()).is_empty())
	_scanner.set_range_multiplier(2.0)
	_ok("a doubled range reads 2200 px",
		is_equal_approx(_scanner.range_now(), 2200.0), "%.0f px" % _scanner.range_now())
	_ok("and the same sweep now reaches it", (await _sweep()).size() == 1)
	_scanner.set_range_multiplier(1.0)

	_clear_world()
	_fake(Vector2(900.0, 0.0), "wrecks", "unknown_object", "")
	_ok("a derelict at 900 px is detected at stock sensitivity",
		(await _sweep()).size() == 1)
	_scanner.set_sensitivity(0.25)
	_ok("a deaf receiver loses it", (await _sweep()).is_empty())
	_scanner.set_sensitivity(1.0)
	_ok("and gets it back", (await _sweep()).size() == 1)
	_scanner.set_sensitivity(100.0)
	_ok("sensitivity is clamped to something sane",
		is_equal_approx(_scanner.sensitivity, 8.0), "%.2f" % _scanner.sensitivity)
	_scanner.set_sensitivity(1.0)


# ------------------------------------------------------------ K. the signals ----

## Signals with no object behind them: rolled from the world's own hash over a fixed
## lattice, so they are in the same place on every sweep and every visit, and they
## stay unnamed until a research stage exists to make sense of them.
func _test_phantoms() -> void:
	print("-- signals")
	var loud: ScannerProfile = _profile(0.4, true)
	for signature in loud.signatures:
		if signature.phantom:
			signature.phantom_chance = 1.0
	_scanner.set_profile(loud)
	_clear_world()
	var first: Array = await _sweep()
	var second: Array = await _sweep()
	var signals := _count_source(first, "signal")
	_ok("a sweep raises signals with nothing behind them", signals > 0,
		"%d of %d contacts" % [signals, first.size()])
	_ok("the same cells raise the same signals", _ids(first) == _ids(second),
		"%d ids" % _ids(first).size())
	var core_ok := true
	var unnamed := true
	var kinds_ok := true
	for contact in first:
		if String(contact.source) != "signal":
			continue
		core_ok = core_ok and String(contact.id).begins_with("sig:")
		unnamed = unnamed and not bool(contact.identified) \
			and String(contact.title).is_empty() and (contact.info as Dictionary).is_empty()
		kinds_ok = kinds_ok and ["anomaly", "unknown_signal"].has(String(contact.kind))
	_ok("a signal's id names its cell", core_ok and signals > 0)
	_ok("a signal is never named and never explained", unnamed and signals > 0)
	_ok("it reads as an anomaly or an unknown signal", kinds_ok and signals > 0,
		str(_kinds(first)))

	var quiet: ScannerProfile = _profile(0.4, true)
	for signature in quiet.signatures:
		if signature.phantom:
			signature.phantom_chance = 0.0
	_scanner.set_profile(quiet)
	_clear_world()
	_ok("a profile with no phantom chance raises none",
		_count_source(await _sweep(), "signal") == 0)


# --------------------------------------------------------- L. the real field ----

## The synthetic world proved the thresholds; this proves the shipping world answers
## the same question, and that a sweep in flight finds real content. The scanner here
## is the one the scene mounts, not one the test built.
func _test_real_world() -> void:
	print("-- the real field")
	# One world per scene is the rule the scanner's group lookup assumes. The
	# synthetic world of phases A-J leaves the group here so the shipping field is
	# the only answer - exactly as it is in the game.
	_world.remove_from_group("world_field")
	var map: Node = MAP_SCENE.instantiate()
	root.add_child(map)
	for i in 90:
		await physics_frame
	var field := map.get_node_or_null("Field")
	var ship := map.get_node_or_null("Ship") as RigidBody2D
	var map_hub := map.get_node_or_null("Ship/Systems") as ShipSystems
	var scanner := map.get_node_or_null("Ship/Systems/Scanner") as ShipScanner
	_ok("the scene mounts a scanner on the ship's systems",
		scanner != null and field != null and ship != null and map_hub != null)
	if scanner == null or field == null or ship == null or map_hub == null:
		map.queue_free()
		await _steps(2)
		return
	var pulses: Array = []
	map_hub.system_event.connect(func(event): pulses.append(event))
	_ok("it is a cold device with a full disc",
		not scanner.enabled and is_equal_approx(scanner.range_now(), 1100.0),
		"%.0f px" % scanner.range_now())
	_ok("it finds the field by group, not by path", scanner.world() == field)

	# Fly the belt: the spawn zone is deliberately cleared, so a sweep at the origin
	# has nothing to find. The hull is flown until the disc actually holds stones,
	# with a frame budget, so the phase cannot depend on how far one burst of thrust
	# happens to carry it.
	Input.action_press("thrust_forward")
	var tries := 0
	var belt: Array = []
	while tries < 600:
		tries += 1
		await physics_frame
		if tries % 20 != 0:
			continue
		belt = _rocky(field.objects_near(ship.global_position, 900.0, 0))
		if belt.size() >= 3:
			break
	Input.action_release("thrust_forward")
	for i in 10:
		await physics_frame
	_ok("the hull reached a belt in a bounded time", belt.size() >= 3,
		"%d stones after %d frames" % [belt.size(), tries])

	var live: int = field.live_count()
	var chunks: int = field.chunk_count()
	var asked := Time.get_ticks_usec()
	var near: Array = field.objects_near(ship.global_position, 1100.0, 0)
	var spent := Time.get_ticks_usec() - asked
	_ok("the field answers an area query", not near.is_empty(), "%d objects" % near.size())
	_ok("everything it answers is inside the disc",
		_near_all_within(near, ship.global_position, 1100.0))
	_ok("nearest first", _sorted_by_distance(near, ship.global_position))
	_ok("the query builds nothing and unloads nothing",
		field.live_count() == live and field.chunk_count() == chunks,
		"%d objects, %d chunks, asked in %d us" % [field.live_count(),
			field.chunk_count(), int(spent)])
	_ok("asked for a bounded list it answers a bounded list",
		field.objects_near(ship.global_position, 1100.0, 3).size() <= 3)
	_ok("a zero radius asks nothing",
		field.objects_near(ship.global_position, 0.0, 0).is_empty())

	scanner.set_profile(_profile(0.6, true))
	var contacts: Array = []
	var guard := 0
	scanner.start_scan()
	while scanner.is_scanning() and guard < 900:
		guard += 1
		await physics_frame
	contacts = scanner.last_contacts()
	_ok("a sweep in flight finds real content", contacts.size() > 0,
		"%d contacts" % contacts.size())
	_ok("every contact is inside the disc", _all_within(contacts, scanner.range_now()))
	_ok("the contacts name their world population", _populations(contacts).size() > 0,
		str(_populations(contacts)))
	_ok("an order lit the cold sensor and put it on the ship's bus",
		scanner.enabled and is_equal_approx(map_hub.power_demand(), 6.0),
		"%.1f units" % map_hub.power_demand())
	var topics: Array = []
	for event in pulses:
		var topic := String(event.data.get("topic", ""))
		if not topic.is_empty():
			topics.append(topic)
	_ok("the ship's own bus heard the sweep and its result",
		topics.has("scan_started") and topics.has("scan_completed"), str(topics))

	var names: Array = []
	for contact in contacts:
		names.append("%s \"%s\"" % [contact.kind, contact.title])
	print("    contacts: ", ", ".join(names))
	map.queue_free()
	await _steps(2)


# ------------------------------------------------------------- M. teardown -----

func _teardown() -> void:
	print("-- teardown")
	_scanner.queue_free()
	await _steps(2)
	_ok("the device leaves the registry", _hub.count() == 0, "%d left" % _hub.count())
	_ok("the hub has no status for it any more",
		_hub.equipment_status("scanner").is_empty())


func _near_all_within(nodes: Array, center: Vector2, radius: float) -> bool:
	for node in nodes:
		var at := node as Node2D
		if at == null or at.global_position.distance_to(center) > radius:
			return false
	return true


func _sorted_by_distance(nodes: Array, center: Vector2) -> bool:
	var last := -1.0
	for node in nodes:
		var at := node as Node2D
		if at == null:
			return false
		var distance := at.global_position.distance_to(center)
		if distance < last:
			return false
		last = distance
	return true


func _all_within(contacts: Array, radius: float) -> bool:
	for contact in contacts:
		if float(contact.get("distance", radius + 1.0)) > radius:
			return false
	return true


func _populations(contacts: Array) -> Array:
	var out: Array = []
	for contact in contacts:
		var population := String(contact.get("population", ""))
		if not population.is_empty() and not out.has(population):
			out.append(population)
	return out


## The solid populations of a list of world objects - the ones a hull can hit, and
## the ones a sweep is guaranteed to name.
func _rocky(nodes: Array) -> Array:
	var out: Array = []
	for node in nodes:
		var population := String(node.get_meta("population", ""))
		if population == "asteroids" or population == "debris":
			out.append(node)
	return out