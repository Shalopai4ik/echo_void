extends SceneTree

## Sub-stage 4.4 verification: the equipment control system.
## Run: godot --headless --path . --script tests/ship_equipment_test.gd
##
## The layer already had devices (`ShipComponent`), a registry, a power bus and a
## damage ledger. This suite holds what the control pass added on top of them, in the
## order the phases run:
##
## 1. registry: a mounted device is filed under its id and answers a structured status;
## 2. switches: on, off, toggle, all-at-once, and an unknown id that is refused;
## 3. activation: the switch-on price is paid once, a lit device cannot pay twice, a
##    short reserve refuses and spends nothing;
## 4. availability: a wrecked device cannot be switched on, the refusal carries the
##    reason, and a repair makes it startable again;
## 5. power: a running device draws its configured appetite, a starved device goes
##    OFFLINE without its switch moving, and restored power revives it by itself;
## 6. damage: DAMAGED still works at reduced efficiency, a wreck draws nothing and
##    cannot be restarted, and repair restores the same rules;
## 7. a destroyed hull refuses every start until it is whole again;
## 8. a new device class mounts, reports and switches with no change to the hub;
## 9. teardown.
##
## The energy clock is disabled throughout so the charge arithmetic is exact; only
## `ship_energy_test` trusts real frames to move the tank.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: ShipController
var _hub: ShipSystems
var _base: ShipSystemsParameters

var _sensor: Probe
var _drill: Probe
var _denials: Array = []
var _refusals := 0


## A device that does nothing except exist. Everything the suite needs about the
## control system is observable from the public API, which is the point.
class Probe extends ShipComponent:
	var heard: Array = []

	func receive_event(event: ShipSystemEvent) -> void:
		heard.append(event)


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


func _on_denied(id: String, reason: String) -> void:
	_denials.append([id, reason])


func _on_refused(_id: String, _cost: float, _available: float) -> void:
	_refusals += 1


## Mount a device the way a scene author would: exports first, then add_child. The
## component registers itself and finds the hub by walking up.
func _mount(id: String, draw: float, priority: int, cost := 0.0,
		start := true) -> Probe:
	var device := Probe.new()
	device.name = id.capitalize()
	device.component_id = id
	device.title = id.capitalize()
	device.nominal_power_draw = draw
	device.power_priority = priority
	device.activation_energy_cost = cost
	device.starts_enabled = start
	_hub.add_child(device)
	return device


## A tuning resource that makes the arithmetic readable: a small tank, no regen, a
## comfortable reactor unless a phase says otherwise.
func _tuning(reactor := 240.0) -> ShipSystemsParameters:
	var p := ShipSystemsParameters.new()
	p.reactor_output = reactor
	p.energy_capacity = 400.0
	p.energy_recharge_rate = 0.0
	p.offline_integrity = 0.15
	p.damaged_integrity = 0.6
	p.impact_damage_enabled = false
	return p


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	_hub = _ship.get_node_or_null("Systems") as ShipSystems
	if _hub == null:
		print("RESULT: FAILED  Ship.tscn has no Systems node")
		quit(2)
		return
	_base = _hub.parameters
	_hub.activation_denied.connect(_on_denied)
	_hub.activation_refused.connect(_on_refused)
	await _steps(3)

	_hub.clock.set_physics_process(false)
	_hub.set_parameters(_tuning())
	_hub.set_energy(400.0)

	_test_registry()
	_test_switches()
	_test_activation()
	_test_availability()
	_test_power()
	_test_damage()
	_test_destroyed_hull()
	_test_new_device()
	await _teardown()

	print("")
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED %d of %d" % [_failed, _checks])
	quit(1 if _failed else 0)


# --------------------------------------------------------------- 1. registry ----

func _test_registry() -> void:
	print("-- registry")
	_sensor = _mount("sensor", 40.0, 10, 20.0, false)
	_drill = _mount("drill", 60.0, 5, 0.0, true)
	_ok("mounted devices join one registry",
		_hub.count() == 2 and _hub.has_component("sensor") and _hub.has_component("drill"),
		", ".join(_hub.component_ids()))
	_ok("the registry returns the mounted device",
		_hub.component("sensor") == _sensor)
	var status := _hub.equipment_status("sensor")
	_ok("a device reports its id and title",
		String(status.get("id", "")) == "sensor"
			and String(status.get("title", "")) == "Sensor", String(status.get("title", "")))
	_ok("a status carries every control field",
		status.has("enabled") and status.has("state") and status.has("state_name")
			and status.has("integrity") and status.has("efficiency")
			and status.has("power_ratio") and status.has("demand")
			and status.has("available") and status.has("can_start")
			and status.has("block_reason"))
	_ok("every device has a status",
		_hub.equipment_statuses().size() == 2)
	_ok("an unknown id has no status and cannot start",
		_hub.equipment_status("nobody").is_empty()
			and not _hub.can_activate("nobody")
			and _hub.activation_block_reason("nobody") == "unknown")


# ---------------------------------------------------------------- 2. switches ---

func _test_switches() -> void:
	print("-- switches")
	_ok("a device can be switched on",
		_hub.set_enabled("sensor", true) and _hub.is_enabled("sensor"))
	_ok("a running device draws its configured appetite",
		is_equal_approx(_hub.power_demand(), 100.0), "%.1f units" % _hub.power_demand())
	_ok("toggle switches it off",
		_hub.toggle_enabled("sensor") and not _hub.is_enabled("sensor"))
	_ok("an off device stops drawing",
		is_equal_approx(_hub.power_demand(), 60.0), "%.1f units" % _hub.power_demand())
	_ok("toggle switches it back on",
		_hub.toggle_enabled("sensor") and _hub.is_enabled("sensor"))
	_ok("an unknown id cannot be toggled", not _hub.toggle_enabled("nobody"))

	_hub.set_all_enabled(false)
	_ok("all devices can be switched off at once",
		is_equal_approx(_hub.power_demand(), 0.0) and not _hub.is_enabled("drill"))
	_hub.set_all_enabled(true)
	_ok("all devices can be switched on at once",
		is_equal_approx(_hub.power_demand(), 100.0)
			and _hub.is_enabled("sensor") and _hub.is_enabled("drill"))


# -------------------------------------------------------------- 3. activation ---

func _test_activation() -> void:
	print("-- activation")
	_hub.set_energy(100.0)
	_hub.set_enabled("sensor", false)
	_ok("activation spends the configured cost once",
		_hub.set_enabled("sensor", true)
			and is_equal_approx(_hub.energy_charge(), 80.0),
		"%.1f units" % _hub.energy_charge())
	_ok("a second press on a lit device costs nothing",
		_hub.set_enabled("sensor", true)
			and is_equal_approx(_hub.energy_charge(), 80.0),
		"%.1f units" % _hub.energy_charge())

	_hub.set_enabled("sensor", false)
	_hub.set_energy(10.0)
	_ok("a short reserve refuses the check", not _hub.can_activate("sensor"))
	_ok("the switch does not move",
		not _hub.set_enabled("sensor", true) and not _hub.is_enabled("sensor"))
	_ok("a refused activation spends nothing",
		is_equal_approx(_hub.energy_charge(), 10.0), "%.1f units" % _hub.energy_charge())
	_hub.set_energy(100.0)


# ------------------------------------------------------------ 4. availability ---

func _test_availability() -> void:
	print("-- availability")
	_hub.set_enabled("sensor", false)
	_hub.apply_damage("sensor", 0.9)
	_ok("a wrecked device may not start",
		not _sensor.can_start() and _hub.activation_block_reason("sensor") == "wrecked",
		_sensor.status_line())
	_ok("a wrecked device fails the activation check",
		not _hub.can_activate("sensor"))

	var denials := _denials.size()
	_ok("its switch cannot move",
		not _hub.set_enabled("sensor", true) and not _hub.is_enabled("sensor"))
	_ok("the refusal carries the reason",
		_denials.size() == denials + 1
			and String(_denials[-1][1]) == "wrecked",
		str(_denials[-1]) if _denials.size() > denials else "none")
	_ok("a refused wrecked start spends nothing",
		is_equal_approx(_hub.energy_charge(), 100.0), "%.1f units" % _hub.energy_charge())

	_hub.repair("sensor", 0.5)
	_ok("a repaired device becomes startable",
		_sensor.can_start() and _hub.can_activate("sensor"))
	_ok("and its switch works again",
		_hub.set_enabled("sensor", true) and _hub.is_enabled("sensor"))


# ------------------------------------------------------------------- 5. power ---

func _test_power() -> void:
	print("-- power")
	var p := _hub.settings()
	p.reactor_output = 40.0
	_hub.set_parameters(p)
	_ok("a starved device goes offline",
		_drill.state == ShipSystemState.Value.OFFLINE, _drill.status_line())
	_ok("a brownout does not throw the crew switch",
		_hub.is_enabled("drill"))
	_ok("its status says it is not available",
		not bool(_hub.equipment_status("drill").get("available", true)))
	_ok("the starved device still asks for its appetite",
		is_equal_approx(_hub.power_demand(), 100.0), "%.1f units" % _hub.power_demand())

	p.reactor_output = 240.0
	_hub.set_parameters(p)
	_ok("restored power revives it without a switch",
		_drill.state == ShipSystemState.Value.NOMINAL and _hub.is_enabled("drill"),
		_drill.status_line())


# ------------------------------------------------------------------ 6. damage ---

func _test_damage() -> void:
	print("-- damage")
	_hub.apply_damage("drill", 0.45)
	_ok("a hurt device is DAMAGED and still works, reduced",
		_drill.state == ShipSystemState.Value.DAMAGED
			and is_equal_approx(_drill.efficiency(), 0.5), _drill.status_line())
	_ok("a damaged device still draws its full appetite",
		is_equal_approx(_hub.power_demand(), 100.0), "%.1f units" % _hub.power_demand())

	_hub.apply_damage("drill", 0.45)
	_ok("a wrecked device goes offline",
		_drill.state == ShipSystemState.Value.OFFLINE, _drill.status_line())
	_ok("a wrecked device draws nothing",
		is_equal_approx(_hub.power_demand(), 40.0)
			and is_equal_approx(float(_hub.equipment_status("drill").get("demand", -1.0)), 0.0),
		"%.1f units" % _hub.power_demand())
	_hub.set_enabled("drill", false)
	var denials := _denials.size()
	_ok("a wrecked device cannot be toggled on",
		not _hub.toggle_enabled("drill") and not _hub.is_enabled("drill"))
	_ok("its denial reason is wrecked",
		_denials.size() == denials + 1
			and String(_denials[-1][1]) == "wrecked",
		str(_denials[-1]) if _denials.size() > denials else "none")

	_hub.repair("drill", 0.6)
	_ok("repair makes it startable through the same rule",
		_drill.can_start() and _hub.set_enabled("drill", true))
	_ok("and nominal once it is above the damage line",
		_drill.state == ShipSystemState.Value.NOMINAL, _drill.status_line())


# --------------------------------------------------------- 7. a destroyed hull ---

func _test_destroyed_hull() -> void:
	print("-- destroyed hull")
	_hub.apply_hull_damage(999.0)
	_ok("the hull is destroyed", _hub.is_hull_destroyed())
	_ok("a wrecked hull blocks every device",
		not _hub.can_activate("sensor")
			and _hub.activation_block_reason("sensor") == "destroyed")
	_hub.set_enabled("sensor", false)
	var denials := _denials.size()
	_ok("no device can be lit on a wreck",
		not _hub.set_enabled("sensor", true) and not _hub.is_enabled("sensor"))
	_ok("the hull reason is reported",
		_denials.size() == denials + 1
			and String(_denials[-1][1]) == "destroyed",
		str(_denials[-1]) if _denials.size() > denials else "none")
	_ok("the refusal spent nothing",
		is_equal_approx(_hub.energy_charge(), 80.0), "%.1f units" % _hub.energy_charge())

	_hub.repair_hull(10.0)
	_ok("a repaired hull allows activation again",
		_hub.can_activate("sensor") and _hub.set_enabled("sensor", true))


# ------------------------------------------------------------ 8. a new device ---

func _test_new_device() -> void:
	print("-- new device")
	_mount("scanner", 15.0, 30, 5.0, false)
	_ok("a new device class registers with no hub change",
		_hub.has_component("scanner") and _hub.count() == 3,
		", ".join(_hub.component_ids()))
	var status := _hub.equipment_status("scanner")
	_ok("it answers the same status shape",
		String(status.get("state_name", "")) == "OFFLINE"
			and bool(status.get("can_start", false))
			and not bool(status.get("enabled", true)))
	_ok("it starts through the same switch",
		_hub.set_enabled("scanner", true)
			and is_equal_approx(_hub.power_demand(), 115.0),
		"%.1f units" % _hub.power_demand())
	_ok("it toggles through the same switch",
		_hub.toggle_enabled("scanner")
			and is_equal_approx(_hub.power_demand(), 100.0))
	_ok("a second start pays the price again",
		_hub.toggle_enabled("scanner")
			and is_equal_approx(_hub.energy_charge(), 50.0),
		"%.1f units" % _hub.energy_charge())


# ---------------------------------------------------------------- 9. teardown ---

func _teardown() -> void:
	print("-- teardown")
	for device in _hub.components():
		device.queue_free()
	await _steps(2)
	_ok("every device leaves the registry", _hub.count() == 0,
		"%d left" % _hub.count())
	_ok("the registry returns empty states",
		_hub.equipment_statuses().is_empty())
	_hub.set_parameters(_base)
	_hub.repair_hull(10.0)
	await _steps(2)
	_ok("the hull is whole for the next suite",
		is_equal_approx(_hub.hull_ratio(), 1.0), "%.2f" % _hub.hull_ratio())