extends SceneTree

## Stage 6 verification: the decoy launcher system.
## Run: godot --headless --path . --script tests/decoy_test.gd

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const DECOY_LAUNCHER := preload("res://scripts/ship/systems/ship_decoy_launcher.gd")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: Node2D
var _hub: ShipSystems
var _launcher
var _broadcaster
var _launched: Array = []
var _refused: Array = []
var _finished: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print((("PASS  " if condition else "FAIL  ") + name + "   " + detail))
	if not condition:
		_failed += 1

func _steps(count: int) -> void:
	for i in count:
		await physics_frame

func _on_launched(_source_id: String, _direction: Vector2, _speed: float, _lifetime: float) -> void:
	_launched.append(true)

func _on_refused(reason: String) -> void:
	_refused.append(reason)

func _on_finished(_source_id: String) -> void:
	_finished.append(true)

func _tuning() -> ShipSystemsParameters:
	var p := ShipSystemsParameters.new()
	p.reactor_output = 240.0
	p.energy_capacity = 400.0
	p.energy_recharge_rate = 0.0
	p.offline_integrity = 0.15
	p.damaged_integrity = 0.6
	return p

func _mount_launcher(id := "decoy_launcher", cost := 30.0, cooldown := 3.0,
                     speed := 150.0, lifetime := 4.0,
                     intensity := 1.0, radius := 600.0, max_concurrent := 2,
                     start := false):
	var device := DECOY_LAUNCHER.new()
	device.name = id.capitalize()
	device.component_id = id
	device.title = id.capitalize()
	device.activation_cost = cost
	device.cooldown_sec = cooldown
	device.decoy_speed = speed
	device.decoy_lifetime = lifetime
	device.signal_intensity = intensity
	device.signal_radius = radius
	device.max_concurrent_decoys = max_concurrent
	device.starts_enabled = start
	_hub.add_child(device)
	return device

func _run() -> void:
	_root = Node2D.new()
	get_root().add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	_hub = _ship.get_node_or_null("Systems") as ShipSystems
	if _hub == null:
		print("RESULT: FAILED  Ship.tscn has no Systems node")
		quit(2)
		return
	_hub.set_parameters(_tuning())
	_hub.set_energy(200.0)
	await _steps(2)

	_broadcaster = get_root().get_node_or_null("SignalBroadcaster")
	if _broadcaster == null:
		print("RESULT: FAILED  no SignalBroadcaster autoload")
		return
	_broadcaster.clear_all()
	await _steps(1)

	# ------------------------------------------------------- A. launch -----

	print("-- launch")
	_launcher = _mount_launcher("launcher", 30.0, 3.0, 150.0, 4.0, 1.0, 600.0, 2)
	_launcher.decoy_launched.connect(_on_launched)
	_launcher.decoy_refused.connect(_on_refused)

	var before := _hub.energy_charge()
	var dir := Vector2(1, 0)
	_ok("launch accepts forward direction", bool(_launcher.launch(dir)))
	_ok("energy was spent once",
		absf(_hub.energy_charge() - (before - 30.0)) <= 0.001,
		"%.1f -> %.1f" % [before, _hub.energy_charge()])
	_ok("launched signal emitted", _launched.size() == 1)
	_ok("cooldown is running", _launcher.cooldown_remaining() > 0.0)
	_ok("one decoy in flight", _launcher.active_decoy_count() == 1)
	_ok("cannot launch during cooldown", not bool(_launcher.launch(dir)))
	_ok("refusal reason is cooldown", _refused.has("cooldown"), str(_refused))
	_refused.clear()

	var decoys_before := _ship.get_node("Systems").get_child_count()
	await _steps(3)
	var decoys_after := _ship.get_node("Systems").get_child_count()
	_ok("no decoy node stays mounted on ship", decoys_after == decoys_before,
		"%d -> %d" % [decoys_before, decoys_after])

	# ------------------------------------------------------- B. movement ---

	print("-- movement and lifetime")
	var decoy_count := 0
	for child in get_root().get_children():
		if child is Decoy:
			decoy_count += 1
	_ok("decoy object exists in world", decoy_count == 1, "%d" % decoy_count)

	var decoy: Decoy = null
	for child in get_root().get_children():
		if child is Decoy:
			decoy = child as Decoy
			break

	var start_pos := decoy.global_position
	await _steps(10)
	_ok("decoy moved from spawn point",
		decoy.global_position.distance_to(start_pos) > 10.0,
		"dist=%.1f" % decoy.global_position.distance_to(start_pos))
	_ok("decoy moving in +X direction", decoy.global_position.x > start_pos.x)

	_ok("time remaining is positive", decoy.time_remaining() > 0.0)
	await _steps(260)
	_ok("decoy removed itself from world", not is_instance_valid(decoy))

	# ------------------------------------------------------- C. cooldown ---

	print("-- cooldown")
	var guard := 0
	while _launcher.cooldown_remaining() > 0.0 and guard < 500:
		guard += 1
		await physics_frame
	_ok("cooldown elapsed", _launcher.cooldown_remaining() < 0.5)
	_ok("can launch after cooldown", bool(_launcher.can_launch_now()))

	# ------------------------------------------------------- D. empty -----

	print("-- empty reserve")
	_hub.set_energy(0.0)
	_ok("activation refused with empty tank", not bool(_launcher.launch(dir)))
	_ok("nothing was spent",
		absf(_hub.energy_charge()) <= 0.001)
	_ok("refusal reason is energy", _refused.has("energy"), str(_refused))
	_hub.set_energy(200.0)

	# ------------------------------------------------------- E. signal -----

	print("-- signal detection")
	_ok("can launch again", bool(_launcher.launch(Vector2(0, 1))))
	await _steps(2)
	var near_ship: Array = _broadcaster.signals_near(_ship.global_position)
	_ok("signal reaches ship position", near_ship.size() > 0,
		"%d signals" % near_ship.size())
	if near_ship.size() > 0:
		_ok("signal kind is decoy", String(near_ship[0]["kind"]).begins_with("decoy:"))
		_ok("signal strength at ship > 0", float(near_ship[0]["strength"]) > 0.0)

	var far := _ship.global_position + Vector2(2000, 0)
	var near_far: Array = _broadcaster.signals_near(far)
	_ok("signal does not reach far away", near_far.size() == 0,
		"%d signals" % near_far.size())

	# ------------------------------------------------------- F. limit -----

	print("-- concurrent limit")
	var small = _mount_launcher("small", 5.0, 0.0, 50.0, 1.0, 1.0, 600.0, 1)
	small.decoy_refused.connect(_on_refused)
	_ok("first launch under limit", bool(small.launch(Vector2(1, 0))))
	_refused.clear()
	_ok("second launch blocked by limit", not bool(small.launch(Vector2(-1, 0))))
	_ok("refusal reason is limit", _refused.has("limit"), str(_refused))
	small.queue_free()
	await _steps(2)

	# ------------------------------------------------------- H. repeat -----

	print("-- repeated launches")
	await _steps(180)
	_ok("cooldown cleared", _launcher.cooldown_remaining() < 0.5)
	_ok("second launch after cooldown", bool(_launcher.launch(Vector2(-1, 0))))
	_ok("two launches recorded", _launched.size() >= 2)

	# ------------------------------------------------------- I. cleanup ---

	print("-- no leftover nodes")
	var leaked := false
	for child in _ship.get_node("Systems").get_children():
		if child.get_class() == "ShipDecoyLauncher":
			continue
		if child is Decoy:
			leaked = true
	_ok("no decoy node remains mounted on ship", not leaked)
	await _steps(260)
	_ok("air is empty after all burns",
		_broadcaster.signals_near(_ship.global_position).size() == 0)

	# --------------------------------------------------------- teardown --

	print("-- teardown")
	_hub.set_energy(200.0)
	_hub.repair_hull(10.0)
	for d in [_launcher]:
		if d != null:
			d.queue_free()
	await _steps(2)
	_ok("device leaves the registry", _hub.count() == 0, "%d left" % _hub.count())
	_broadcaster.clear_all()
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED %d of %d" % [_failed, _checks])
	quit(_failed)

