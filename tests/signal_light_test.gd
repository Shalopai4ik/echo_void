extends SceneTree

## Stage 6 verification: the signal light system.
## Run: godot --headless --path . --script tests/signal_light_test.gd
##
## The ship already has equipment, power and a survey scanner; this suite holds the
## signal light to the brief:
##
##   A. activation lights the beacon and spends energy once;
##   B. the beacon burns for its duration and then removes itself from the air;
##   C. a second burn is blocked by cooldown until the first one is done;
##   D. an empty reserve refuses without spending;
##   E. the switch, a brownout and a destroyed hull end a burn early;
##   F. signals reach the broadcaster and answers `signals_near()` near and far;
##   G. the temporary signal object leaves no node behind;
##   H. teardown.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const SHIP_SIGNAL_LIGHT := preload("res://scripts/ship/systems/signal_light_system.gd")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: Node2D
var _hub: ShipSystems
var _beacon
var _broadcaster
var _refusals: Array = []
var _activated: Array = []
var _deactivated: Array = []
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


func _on_refused(reason: String) -> void:
	_refusals.append(reason)


func _on_activated(_duration: float, _intensity: float, _radius: float) -> void:
	_activated.append(true)


func _on_deactivated(reason: String) -> void:
	_deactivated.append(reason)


func _on_finished() -> void:
	_finished.append(true)


func _tuning() -> ShipSystemsParameters:
	var p := ShipSystemsParameters.new()
	p.reactor_output = 240.0
	p.energy_capacity = 400.0
	p.energy_recharge_rate = 0.0
	p.offline_integrity = 0.15
	p.damaged_integrity = 0.6
	return p


func _mount_beacon(id := "beacon", cost := 20.0, duration := 1.0,
                   cooldown := 3.0, intensity := 1.0, radius := 600.0,
                   start := false):
	var device := SHIP_SIGNAL_LIGHT.new()
	device.name = id.capitalize()
	device.component_id = id
	device.title = id.capitalize()
	device.activation_cost = cost
	device.duration_sec = duration
	device.cooldown_sec = cooldown
	device.intensity = intensity
	device.radius_px = radius
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

	# ------------------------------------------------------ A. activation -----

	print("-- activation")
	_beacon = _mount_beacon("beacon", 20.0, 1.0, 3.0, 1.0, 600.0)
	_beacon.signal_activated.connect(_on_activated)
	_beacon.signal_refused.connect(_on_refused)
	_beacon.signal_deactivated.connect(_on_deactivated)
	_beacon.signal_finished.connect(_on_finished)
	var before := _hub.energy_charge()
	var ok := bool(_beacon.call("activate"))
	_ok("activation returns true", ok, str(ok))
	_ok("beacon is signaling", bool(_beacon.call("is_signaling")))
	_ok("energy was spent once",
		is_equal_approx(_hub.energy_charge(), before - 20.0),
		"%.1f vs %.1f" % [_hub.energy_charge(), before - 20.0])
	_ok("activation signal fired", _activated.size() == 1, str(_activated.size()))
	_ok("time remaining is duration",
		absf(float(_beacon.call("time_remaining")) - 1.0) < 0.5,
		"%.2f" % _beacon.call("time_remaining"))
	_ok("cooldown reads 0 while active",
		is_equal_approx(float(_beacon.call("cooldown_remaining")), 0.0))
	_ok("cannot activate again while burning", not bool(_beacon.call("can_activate_now")))

	# ------------------------------------------------- F. detection, near -----

	print("-- detection")
	var at := _ship.global_position
	var near: Array = _broadcaster.signals_near(at)
	_ok("signal is heard at the source", near.size() >= 1, str(near.size()))
	if near.size() >= 1:
		_ok("signal strength at source is full",
			absf(near[0]["strength"] - 1.0) < 0.01,
			"%.2f" % near[0]["strength"])
		_ok("signal carries the source id",
			String(near[0]["source_id"]).begins_with("signal_light:"),
			str(near[0]["source_id"]))

	var far := at + Vector2(700.0, 0.0)
	var distant: Array = _broadcaster.signals_near(far)
	_ok("signal is not heard beyond its radius", distant.size() == 0,
		str(distant.size()))

	# ------------------------------------------------- B. burn and finish -----

	print("-- burn and finish")
	var guard := 0
	while bool(_beacon.call("is_signaling")) and guard < 300:
		guard += 1
		await physics_frame
	_ok("burn ended on its own", not bool(_beacon.call("is_signaling")), "guard=%d" % guard)
	_ok("finished signal fired", _finished.size() == 1, str(_finished.size()))
	_ok("deactivated reason is finished",
		_deactivated.has("finished"), str(_deactivated))
	_ok("time remaining reads 0 after burn",
		is_equal_approx(float(_beacon.call("time_remaining")), 0.0))
	_ok("signal left the air", _broadcaster.signals_near(at).size() == 0,
		str(_broadcaster.signals_near(at).size()))

	# ------------------------------------------------- C. cooldown -----------

	print("-- cooldown")
	_ok("cooldown is running after burn",
		float(_beacon.call("cooldown_remaining")) > 0.0,
		"%.2f" % _beacon.call("cooldown_remaining"))
	_ok("cannot activate during cooldown", not bool(_beacon.call("activate")))
	var guard2 := 0
	while float(_beacon.call("cooldown_remaining")) > 0.0 and guard2 < 500:
		guard2 += 1
		await physics_frame
	_ok("cooldown elapsed",
		absf(float(_beacon.call("cooldown_remaining"))) < 0.5,
		"%.2f" % _beacon.call("cooldown_remaining"))
	_ok("can activate after cooldown", bool(_beacon.call("can_activate_now")))

	# ------------------------------------------------- D. empty reserve ------

	print("-- empty reserve")
	_hub.set_energy(0.0)
	_ok("activation refused with empty tank", not bool(_beacon.call("activate")))
	_ok("nothing was spent",
		absf(_hub.energy_charge()) < 0.001)
	_hub.set_energy(200.0)

	# ------------------------------------------------- E. early endings ------

	print("-- switched off")
	var off = _mount_beacon("offbeacon", 20.0, 60.0, 3.0, 1.0, 600.0)
	off.signal_deactivated.connect(_on_deactivated)
	off.call("activate")
	_ok("burning", bool(off.call("is_signaling")))
	_hub.set_enabled("offbeacon", false)
	await _steps(2)
	_ok("switching off ends the burn", not bool(off.call("is_signaling")))
	_ok("deactivated reason is switched_off",
		_deactivated.has("switched_off"), str(_deactivated))

	print("-- brownout")
	var brown = _mount_beacon("brownbeacon", 20.0, 60.0, 3.0, 1.0, 600.0)
	brown.signal_deactivated.connect(_on_deactivated)
	brown.call("activate")
	_ok("burning again", bool(brown.call("is_signaling")))
	_hub.set_energy(0.0)
	await _steps(2)
	_ok("brownout ends the burn", not bool(brown.call("is_signaling")))
	_ok("deactivated reason is unpowered",
		_deactivated.has("unpowered"), str(_deactivated))
	_hub.set_energy(200.0)

	print("-- destroyed hull")
	var hull = _mount_beacon("hullbeacon", 20.0, 60.0, 3.0, 1.0, 600.0)
	hull.signal_deactivated.connect(_on_deactivated)
	hull.call("activate")
	_ok("burning before hull loss", bool(hull.call("is_signaling")))
	_hub.apply_hull_damage(999.0)
	await _steps(2)
	_ok("destroyed hull ends the burn", not bool(hull.call("is_signaling")))
	_ok("deactivated reason is hull_destroyed",
		_deactivated.has("hull_destroyed"), str(_deactivated))

	# ------------------------------------------------ G. no leftover node ----

	print("-- no leftover node")
	var leaked := false
	for child in _ship.get_node("Systems").get_children():
		if child.get_class() == "ShipSignalLight":
			leaked = true
	_ok("no signal light node remains mounted", not leaked)
	_ok("air is empty after all burns",
		_broadcaster.signals_near(_ship.global_position).size() == 0)

	# ------------------------------------------------------------- teardown --

	print("-- teardown")
	_hub.set_energy(200.0)
	_hub.repair_hull(10.0)
	for b in [_beacon, off, brown, hull]:
		if b != null:
			b.call("queue_free")
	await _steps(2)
	_ok("device leaves the registry", _hub.count() == 0,
		"%d left" % _hub.count())
	_broadcaster.clear_all()
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED %d of %d" % [_failed, _checks])
	# The suite has to end the process itself: a headless SceneTree keeps
	# running after the last check, and the runner would wait forever.
	quit(1 if _failed > 0 else 0)
