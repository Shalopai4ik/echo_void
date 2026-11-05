extends SceneTree

## Stage 4.5 verification: how the hull's systems behave *together*.
## Run: godot --headless --path . --script tests/ship_integration_test.gd
##
## The earlier suites hold each seam on its own: 4.1 the architecture, 4.2 the reserve,
## 4.3 the hull ledger, 4.4 the control surface. This one holds the wires between them,
## in the order the phases run:
##
## 1. normal operation: everything mounted, powered and NOMINAL;
## 2. several devices at once: priority order, one grant per device, no double count;
## 3. switches: one device off frees its appetite for the others, and only for them;
## 4. activation: the surge is paid once, an idempotent start is free, a short reserve
##    refuses and spends nothing;
## 5. depletion: the bus goes dark, every device stops, the tank stops at zero, the
##    restart line prevents flapping and recovery revives devices by itself;
## 6. hull damage during work: a wounded device degrades, a wreck stops drawing, its
##    neighbours keep their grants, and repair restores the same rules;
## 7. a wrecked device cannot start and cannot spend: the refusal carries a reason and
##    the reserve does not move;
## 8. destruction: the plant is cut, every device - including a passive one - goes
##    OFFLINE, the tank is frozen, nothing can be activated, and a repair brings the
##    ship back under the same switches;
## 9. a damaged power source: its supply scales with integrity, wrecking it browns out
##    the hull, and repairing it restores the budget;
## 10. repeated and hostile input: a re-entrant impact lands one wound, NaN and infinity
##     cannot poison the reserve, and two spends cannot share one unit;
## 11. the panel prints what happened; 12. teardown leaves the hull whole.
##
## The clock is disabled throughout, so every unit of charge in this file moved because
## the test moved it. Only `ship_energy_test` trusts real frames to drain the tank.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: ShipController
var _hub: ShipSystems
var _base: ShipSystemsParameters

var _denials: Array = []
var _refusals := 0
var _destroyed_events := 0
var _depleted_events := 0
var _restored_events := 0
var _low_events := 0

var _sensor: Probe
var _drill: Probe
var _scanner: Probe


## A device that does nothing except exist, hear the bus and remember. The subclass adds
## the one hostile behaviour the last phase needs: an event handler that tries to start
## a whole new impact from inside an impact.
class Probe extends ShipComponent:
	var heard: Array = []

	func receive_event(event: ShipSystemEvent) -> void:
		heard.append(event)


class Echo extends Probe:
	var echo := true
	var nested_result: Variant = "not called"

	func receive_event(event: ShipSystemEvent) -> void:
		super.receive_event(event)
		if echo and event.kind == ShipSystemEvent.Kind.IMPACT:
			echo = false
			nested_result = systems.call("report_impact", {
				"closing_speed": 900.0, "category": "HEAVY",
				"contact_point": Vector2.ZERO,
			})


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


func _on_destroyed() -> void:
	_destroyed_events += 1


func _on_depleted() -> void:
	_depleted_events += 1


func _on_restored() -> void:
	_restored_events += 1


func _on_low(_ratio: float) -> void:
	_low_events += 1
## A tuning resource with the numbers this phase needs, fresh each time so no phase
## inherits a rate or a line from the one before it.
func _tuning(reactor := 240.0, capacity := 400.0, recharge := 0.0) -> ShipSystemsParameters:
	var p := ShipSystemsParameters.new()
	p.reactor_output = reactor
	p.energy_capacity = capacity
	p.energy_recharge_rate = recharge
	p.energy_low_ratio = 0.25
	p.energy_restart_ratio = 0.1
	p.offline_integrity = 0.15
	p.damaged_integrity = 0.6
	p.offline_power_ratio = 0.05
	p.damaged_power_ratio = 0.5
	p.impact_damage_enabled = true
	p.heavy_impact_damage = 0.2
	p.medium_impact_damage = 0.1
	p.light_impact_damage = 0.01
	p.component_hit_radius = 0.0
	_hub.set_parameters(p)
	return p


## Mount a device the way a scene author would: exports first, then the node. Registration
## is `_ready()`, so nothing else is called here.
func _mount(id: String, draw: float, priority: int, cost := 0.0,
		start := true, supply := 0.0) -> Probe:
	var device := Probe.new()
	device.name = id.capitalize()
	device.component_id = id
	device.title = id.capitalize()
	device.nominal_power_draw = draw
	device.power_priority = priority
	device.activation_energy_cost = cost
	device.starts_enabled = start
	device.power_supply = supply
	_hub.add_child(device)
	return device


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
	_hub.clock.set_physics_process(false)
	_hub.activation_denied.connect(_on_denied)
	_hub.activation_refused.connect(_on_refused)
	_hub.hull_destroyed.connect(_on_destroyed)
	_hub.energy.depleted.connect(_on_depleted)
	_hub.energy.restored.connect(_on_restored)
	_hub.energy.low_charge.connect(_on_low)
	await _steps(2)

	await _test_normal()
	await _test_many_devices()
	await _test_switches()
	await _test_activation()
	await _test_depletion()
	await _test_hull_damage()
	await _test_wrecked_device()
	await _test_destruction()
	await _test_power_source()
	await _test_repeats_and_edges()
	_test_panel()
	await _teardown()

	print("")
	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
# ------------------------------------------------------- 1. normal operation -----

func _test_normal() -> void:
	print("-- normal operation")
	_tuning()
	_hub.set_energy(400.0)
	_sensor = _mount("sensor", 40.0, 30)
	_drill = _mount("drill", 30.0, 10)
	await _steps(1)

	_ok("both devices are mounted", _hub.count() == 2,
		", ".join(_hub.component_ids()))
	_ok("both are powered and nominal",
		_sensor.is_operational() and _drill.is_operational()
			and _sensor.power_ratio == 1.0 and _drill.power_ratio == 1.0,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])
	_ok("the bus reports the whole demand as granted",
		is_equal_approx(_hub.power_demand(), 70.0)
			and is_equal_approx(_hub.power_granted(), 70.0),
		"granted %.1f of %.1f units" % [_hub.power_granted(), _hub.power_output()])
	_ok("there is no brownout and no alarm",
		not _hub.is_brownout() and not _hub.is_energy_low()
			and not _hub.is_energy_depleted())
	_ok("the ship's aggregate state is nominal",
		_hub.state() == ShipSystemState.Value.NOMINAL, _hub.state_name())
	_ok("the hull is whole", is_equal_approx(_hub.hull_ratio(), 1.0),
		"%.2f" % _hub.hull_ratio())


# ------------------------------------------------------ 2. many devices at once --

func _test_many_devices() -> void:
	print("-- several devices at once")
	_tuning(60.0, 400.0)
	_hub.set_energy(400.0)
	_scanner = _mount("scanner", 15.0, 20)
	await _steps(1)

	# Priorities 30 / 20 / 10 against a 60-unit reactor: 40 + 15 + 5.
	_ok("the highest priority is served in full", _sensor.power_ratio == 1.0,
		_sensor.status_line())
	_ok("the middle device is served in full", _scanner.power_ratio == 1.0,
		_scanner.status_line())
	_ok("the lowest priority takes what is left",
		is_equal_approx(_drill.power_ratio, 5.0 / 30.0), _drill.status_line())
	_ok("a starved device reads DAMAGED, not NOMINAL",
		_drill.state == ShipSystemState.Value.DAMAGED, _drill.status_line())
	_ok("the bus knows it went short", _hub.is_brownout())
	_ok("demand and grant are counted once each",
		is_equal_approx(_hub.power_demand(), 85.0)
			and is_equal_approx(_hub.power_granted(), 60.0),
		"demand %.1f granted %.1f" % [_hub.power_demand(), _hub.power_granted()])
	_ok("the grants add up to the budget",
		is_equal_approx(_sensor.power_ratio * 40.0 + _scanner.power_ratio * 15.0
			+ _drill.power_ratio * 30.0, 60.0),
		"%.3f units" % (_sensor.power_ratio * 40.0 + _scanner.power_ratio * 15.0
			+ _drill.power_ratio * 30.0))
	_ok("the starved device works at reduced efficiency",
		is_equal_approx(_drill.efficiency(), 0.5),
		"%.2f" % _drill.efficiency())


# ------------------------------------------------------------- 3. switches ------

func _test_switches() -> void:
	print("-- switches")
	_hub.set_enabled("scanner", false)
	_ok("the switched-off device leaves the bus",
		not _scanner.enabled and not _scanner.draws_power()
			and _scanner.state == ShipSystemState.Value.OFFLINE,
		_scanner.status_line())
	_ok("the freed appetite goes to the starved device",
		is_equal_approx(_drill.power_ratio, 20.0 / 30.0), _drill.status_line())
	_ok("the other device is not disturbed",
		_sensor.power_ratio == 1.0 and _sensor.enabled, _sensor.status_line())

	_hub.set_enabled("sensor", false)
	_ok("switching the top device off feeds the rest",
		_drill.power_ratio == 1.0
			and _drill.state == ShipSystemState.Value.NOMINAL, _drill.status_line())
	_ok("and the bus is no longer short", not _hub.is_brownout(),
		"%.1f units" % _hub.power_granted())

	_ok("the top device can be switched back on",
		_hub.set_enabled("sensor", true) and _sensor.enabled)
	_ok("switching one device never moves another's switch",
		_sensor.enabled and _drill.enabled and not _scanner.enabled)

	_tuning(240.0, 400.0)
	_hub.set_energy(400.0)
	await _steps(1)
	_ok("a retuned reactor restores every device by itself",
		_sensor.power_ratio == 1.0 and _drill.power_ratio == 1.0,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])
# ----------------------------------------------------------- 4. activation ------

func _test_activation() -> void:
	print("-- activation cost")
	_tuning(240.0, 400.0)
	_hub.set_energy(100.0)
	var railgun := _mount("railgun", 20.0, 5, 20.0, false)
	await _steps(1)

	var refusals := _refusals
	_ok("the switch costs its surge once",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 80.0),
		"%.1f units" % _hub.energy_charge())
	_ok("a device already lit pays nothing",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 80.0),
		"%.1f units" % _hub.energy_charge())
	_hub.set_enabled("railgun", false)
	_ok("a second start pays the price again",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 60.0),
		"%.1f units" % _hub.energy_charge())
	_ok("no refusal was raised for a paid start", _refusals == refusals)

	_hub.set_enabled("railgun", false)
	_hub.set_energy(5.0)
	var denials := _denials.size()
	_ok("a short reserve refuses the start",
		not _hub.can_activate("railgun") and not _hub.set_enabled("railgun", true),
		_hub.activation_block_reason("railgun"))
	_ok("the refusal is an energy refusal, not a hull one",
		_refusals == refusals + 1 and _denials.size() == denials)
	_ok("a refused start spends nothing and moves nothing",
		is_equal_approx(_hub.energy_charge(), 5.0) and not railgun.enabled,
		"%.1f units" % _hub.energy_charge())
	_hub.set_energy(40.0)
	_ok("a funded start works afterwards",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 20.0),
		"%.1f units" % _hub.energy_charge())

	railgun.queue_free()
	await _steps(1)


# ----------------------------------------------------------- 5. depletion ------

func _test_depletion() -> void:
	print("-- depletion")
	_tuning(240.0, 100.0)
	_hub.set_energy(100.0)
	await _steps(1)
	_ok("the hull starts the phase with everything running",
		_sensor.power_ratio == 1.0 and _drill.power_ratio == 1.0,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])

	var drained := _depleted_events
	_hub.set_energy(0.0)
	_ok("an empty tank is reported once",
		_hub.is_energy_depleted() and _depleted_events == drained + 1,
		"%d events" % (_depleted_events - drained))
	_ok("the bus is dark and nothing is granted",
		is_zero_approx(_hub.power_output()) and is_zero_approx(_hub.power_granted()),
		"%.1f / %.1f" % [_hub.power_granted(), _hub.power_output()])
	_ok("every device stops drawing",
		_sensor.state == ShipSystemState.Value.OFFLINE
			and _drill.state == ShipSystemState.Value.OFFLINE,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])
	_ok("the crew switches did not move",
		_sensor.enabled and _drill.enabled)

	_hub.set_energy(0.0)
	_hub.energy.advance(1.0)
	_ok("a blackout cannot go negative and does not announce twice",
		is_zero_approx(_hub.energy_charge()) and _depleted_events == drained + 1,
		"%.2f units" % _hub.energy_charge())

	var restarts := _restored_events
	_hub.add_energy(5.0)
	_ok("charge below the restart line keeps the bus dark",
		_hub.is_energy_depleted() and is_zero_approx(_hub.power_output())
			and _restored_events == restarts,
		"%.1f units" % _hub.energy_charge())
	_hub.add_energy(10.0)
	_ok("crossing the restart line restores the bus once",
		not _hub.is_energy_depleted() and _hub.power_output() > 0.0
			and _restored_events == restarts + 1,
		"%.1f units" % _hub.energy_charge())
	_ok("the devices come back by themselves, switches untouched",
		_sensor.power_ratio == 1.0 and _drill.power_ratio == 1.0
			and _sensor.state == ShipSystemState.Value.NOMINAL,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])

	var lows := _low_events
	_hub.set_energy(30.0)
	_hub.set_energy(20.0)
	_ok("the low line is an alarm, not a failure",
		_hub.is_energy_low() and _low_events == lows + 1
			and _sensor.state == ShipSystemState.Value.NOMINAL,
		"%.0f%%" % (_hub.energy_ratio() * 100.0))
	_hub.set_energy(30.0)
	_ok("climbing out of the low band re-arms the alarm", not _hub.is_energy_low())
	_hub.set_energy(20.0)
	_ok("the next crossing raises it again", _low_events == lows + 2,
		"%d alarms" % (_low_events - lows))


# -------------------------------------------------------- 6. hull damage -------
func _test_hull_damage() -> void:
	print("-- hull damage during work")
	_tuning(240.0, 400.0)
	_hub.set_energy(400.0)
	await _steps(1)
	_ok("the phase starts with two nominal devices",
		_sensor.integrity == 1.0 and _drill.integrity == 1.0,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])

	var applied := _hub.apply_damage("sensor", 0.5, "arc")
	_ok("damage is applied exactly once",
		is_equal_approx(applied, 0.5) and is_equal_approx(_sensor.integrity, 0.5),
		"applied %.2f, left %.2f" % [applied, _sensor.integrity])
	_ok("a wounded device is DAMAGED but still works",
		_sensor.state == ShipSystemState.Value.DAMAGED
			and is_equal_approx(_sensor.efficiency(), 0.5),
		_sensor.status_line())
	_ok("it still asks for its whole appetite",
		is_equal_approx(_hub.power_demand(), 70.0)
			and _sensor.power_ratio == 1.0,
		"demand %.1f" % _hub.power_demand())
	_ok("its neighbour is untouched",
		_drill.integrity == 1.0
			and _drill.state == ShipSystemState.Value.NOMINAL
			and _drill.power_ratio == 1.0, _drill.status_line())

	_hub.apply_damage("sensor", 0.4, "arc")
	_ok("a wrecked device goes OFFLINE and stops drawing",
		_sensor.integrity <= 0.15
			and _sensor.state == ShipSystemState.Value.OFFLINE
			and not _sensor.draws_power(), _sensor.status_line())
	_ok("the freed appetite is shared out, not lost",
		is_equal_approx(_hub.power_demand(), 30.0)
			and _drill.power_ratio == 1.0,
		"demand %.1f" % _hub.power_demand())

	_hub.repair("sensor", 0.5)
	_ok("repair restores the device through the same rule",
		is_equal_approx(float(_hub.equipment_status("sensor").get("integrity", 0.0)), 0.6)
			and _sensor.state == ShipSystemState.Value.NOMINAL,
		_sensor.status_line())
	_ok("and its appetite is back on the bus",
		is_equal_approx(_hub.power_demand(), 70.0)
			and is_equal_approx(_hub.power_granted(), 70.0),
		"demand %.1f granted %.1f" % [_hub.power_demand(), _hub.power_granted()])

	var before := _sensor.integrity
	_hub.apply_hull_damage(0.8)
	_ok("hull damage does not wound a device out of nowhere",
		is_equal_approx(_sensor.integrity, before), _sensor.status_line())
	_ok("the hull reports critical once it crosses the line",
		_hub.is_hull_critical() and _hub.hull_ratio() <= 0.25,
		"%.0f%%" % (_hub.hull_ratio() * 100.0))
	_hub.repair_hull(999.0)
	_ok("a repaired hull is whole and no longer critical",
		not _hub.is_hull_critical() and is_equal_approx(_hub.hull_ratio(), 1.0),
		"%.2f" % _hub.hull_ratio())


# ------------------------------------------------------- 7. wrecked device -----

func _test_wrecked_device() -> void:
	print("-- wrecked device")
	_hub.apply_damage("scanner", 0.95, "arc")
	_ok("the scanner is a wreck",
		_scanner.integrity <= 0.15 and not _scanner.can_start(),
		_scanner.status_line())

	var denials := _denials.size()
	var charge := _hub.energy_charge()
	_ok("a wrecked device cannot be switched on",
		not _hub.set_enabled("scanner", true) and not _scanner.enabled,
		_hub.activation_block_reason("scanner"))
	_ok("the refusal names the device's own condition",
		_denials.size() == denials + 1
			and String(_denials[-1][1]) == "wrecked",
		str(_denials[-1]) if _denials.size() > denials else "none")
	_ok("a wrecked device cannot spend the reserve either",
		not _hub.spend_energy("scanner", 10.0)
			and is_equal_approx(_hub.energy_charge(), charge),
		"%.1f units" % _hub.energy_charge())

	_hub.repair("scanner", 1.0)
	_ok("a repaired device starts again through the same door",
		_scanner.can_start() and _hub.set_enabled("scanner", true)
			and _scanner.state == ShipSystemState.Value.NOMINAL,
		_scanner.status_line())
	_hub.set_enabled("scanner", false)


# ---------------------------------------------------------- 8. destruction ----
func _test_destruction() -> void:
	print("-- destruction")
	_tuning(240.0, 400.0)
	_hub.set_energy(200.0)
	var beacon := _mount("beacon", 0.0, 0)
	await _steps(1)
	_ok("the hull runs three devices before the hit",
		_sensor.state == ShipSystemState.Value.NOMINAL
			and _drill.state == ShipSystemState.Value.NOMINAL
			and beacon.state == ShipSystemState.Value.NOMINAL,
		"%s / %s / %s" % [_sensor.status_line(), _drill.status_line(),
			beacon.status_line()])

	var destroyed := _destroyed_events
	_hub.apply_hull_damage(999.0)
	_ok("the hull is destroyed and says so once",
		_hub.is_hull_destroyed() and _destroyed_events == destroyed + 1,
		"%d events" % (_destroyed_events - destroyed))
	_ok("the plant is cut with the hull",
		not _hub.energy.is_bus_online() and is_zero_approx(_hub.power_output()),
		"output %.1f" % _hub.power_output())
	_ok("every powered device stops",
		_sensor.state == ShipSystemState.Value.OFFLINE
			and _drill.state == ShipSystemState.Value.OFFLINE,
		"%s / %s" % [_sensor.status_line(), _drill.status_line()])
	_ok("a passive device stops too: nothing works on a wreck",
		beacon.state == ShipSystemState.Value.OFFLINE and beacon.enabled,
		beacon.status_line())

	var held := _hub.energy_charge()
	_hub.energy.advance(1.0)
	_ok("a wreck neither draws nor regenerates",
		is_equal_approx(_hub.energy_charge(), held) and held > 0.0,
		"%.1f units" % _hub.energy_charge())

	_hub.set_enabled("sensor", false)
	var denials := _denials.size()
	_ok("nothing can be lit on a wreck",
		not _hub.set_enabled("sensor", true)
			and _hub.activation_block_reason("sensor") == "destroyed")
	_ok("the refusal is reported with the hull reason",
		_denials.size() == denials + 1
			and String(_denials[-1][1]) == "destroyed",
		str(_denials[-1]) if _denials.size() > denials else "none")
	_ok("a wreck cannot pay for an action",
		not _hub.spend_energy("drill", 10.0)
			and is_equal_approx(_hub.energy_charge(), held),
		"%.1f units" % _hub.energy_charge())
	_ok("not even through the reserve's own door",
		not _hub.energy.try_spend(1.0)
			and is_equal_approx(_hub.energy_charge(), held))

	_ok("a second lethal hit is not another wound",
		is_zero_approx(_hub.apply_hull_damage(999.0))
			and _destroyed_events == destroyed + 1)
	_ok("an impact on a wreck changes nothing",
		_hub.report_impact({"closing_speed": 900.0, "category": "HEAVY",
			"contact_point": Vector2.ZERO}) != null
			and is_zero_approx(_hub.hull_integrity()),
		"%.2f hull" % _hub.hull_integrity())

	_hub.repair_hull(999.0)
	_ok("a repaired hull brings the plant back",
		not _hub.is_hull_destroyed() and _hub.energy.is_bus_online(),
		"output %.1f" % _hub.power_output())
	_ok("the devices follow their own switches again",
		_sensor.state == ShipSystemState.Value.OFFLINE and not _sensor.enabled
			and _drill.state == ShipSystemState.Value.NOMINAL
			and beacon.state == ShipSystemState.Value.NOMINAL,
		"%s / %s / %s" % [_sensor.status_line(), _drill.status_line(),
			beacon.status_line()])
	_ok("a device switched off on a wreck can be lit again after repair",
		_hub.set_enabled("sensor", true)
			and _sensor.state == ShipSystemState.Value.NOMINAL,
		_sensor.status_line())
	_ok("the hull did not announce a second destruction",
		_destroyed_events == destroyed + 1)
	_ok("the reserve survived the wreck without being spent",
		is_equal_approx(_hub.energy_charge(), held),
		"%.1f units" % _hub.energy_charge())

	beacon.queue_free()
	await _steps(1)
# ------------------------------------------------------- 9. power source -------
func _test_power_source() -> void:
	print("-- damaged power source")
	_tuning(60.0, 10000.0)
	_hub.set_energy(10000.0)
	var pump := _mount("pump", 110.0, 1)
	var generator := _mount("generator", 0.0, 0, 0.0, true, 120.0)
	await _steps(1)

	_ok("a generator adds its units to the budget",
		is_equal_approx(_hub.power_output(), 180.0)
			and is_equal_approx(_hub.energy.device_supply(), 120.0),
		"output %.1f" % _hub.power_output())
	_ok("everyone is served while the generator is whole",
		pump.state == ShipSystemState.Value.NOMINAL
			and _sensor.power_ratio == 1.0 and _drill.power_ratio == 1.0,
		"%s / %s" % [pump.status_line(), _drill.status_line()])

	_hub.apply_damage("generator", 0.5, "impact")
	_ok("a wounded generator supplies what is left of it",
		is_equal_approx(_hub.energy.device_supply(), 60.0)
			and is_equal_approx(_hub.power_output(), 120.0),
		"supply %.1f, output %.1f" % [_hub.energy.device_supply(),
			_hub.power_output()])
	_ok("the shortfall lands on the lowest priority",
		is_equal_approx(pump.power_ratio, 50.0 / 110.0)
			and pump.state == ShipSystemState.Value.DAMAGED
			and _sensor.power_ratio == 1.0,
		pump.status_line())
	_ok("the panel shows the device supply",
		"\n".join(_hub.report()).contains("supply"))

	_hub.apply_damage("generator", 0.4, "impact")
	_ok("a wrecked generator supplies nothing",
		is_zero_approx(_hub.energy.device_supply())
			and is_equal_approx(_hub.power_output(), 60.0),
		"output %.1f" % _hub.power_output())
	_ok("the hull browns out without touching a single switch",
		pump.state == ShipSystemState.Value.OFFLINE
			and is_equal_approx(_drill.power_ratio, 20.0 / 30.0)
			and _sensor.state == ShipSystemState.Value.NOMINAL
			and pump.enabled and _drill.enabled,
		"%s / %s" % [pump.status_line(), _drill.status_line()])

	_hub.repair("generator", 1.0)
	_ok("repairing the generator restores the budget",
		is_equal_approx(_hub.power_output(), 180.0)
			and pump.state == ShipSystemState.Value.NOMINAL
			and is_equal_approx(_hub.power_granted(), 180.0),
		"output %.1f, granted %.1f" % [_hub.power_output(), _hub.power_granted()])

	_hub.set_enabled("generator", false)
	_ok("switching the generator off takes its supply with it",
		is_zero_approx(_hub.energy.device_supply())
			and is_equal_approx(_hub.power_output(), 60.0),
		"output %.1f" % _hub.power_output())
	_ok("and leaves the other switches alone",
		_sensor.enabled and _drill.enabled and pump.enabled)
	_hub.set_enabled("generator", true)
	_ok("switching it back on restores the same output",
		is_equal_approx(_hub.power_output(), 180.0)
			and pump.state == ShipSystemState.Value.NOMINAL,
		"output %.1f" % _hub.power_output())

	generator.power_supply = NAN
	_hub.energy.allocate()
	_ok("a non-finite supply is not a supply",
		is_equal_approx(_hub.power_output(), 60.0)
			and is_finite(_hub.power_granted()),
		"output %.1f" % _hub.power_output())
	generator.power_supply = 120.0
	_hub.energy.allocate()
	_ok("and the budget comes back with the number",
		is_equal_approx(_hub.power_output(), 180.0),
		"output %.1f" % _hub.power_output())

	generator.queue_free()
	pump.queue_free()
	await _steps(1)
	_ok("unmounting the pair leaves the original devices",
		_hub.count() == 3 and is_zero_approx(_hub.energy.device_supply()),
		", ".join(_hub.component_ids()))
# ------------------------------------------------- 10. repeats and edges -----

func _test_repeats_and_edges() -> void:
	print("-- repeated events and boundaries")
	_tuning(240.0, 400.0)
	_hub.set_energy(400.0)
	_hub.repair_hull(999.0)
	await _steps(1)

	var echo := Echo.new()
	echo.name = "Echo"
	echo.component_id = "echo"
	_hub.add_child(echo)
	await _steps(1)
	var impacts := _hub.damage.impact_count
	var hull_before := _hub.hull_integrity()
	var before_sensor_impacts := _count_impacts(_sensor.heard)
	var event := _hub.report_impact({"closing_speed": 900.0, "category": "HEAVY",
		"contact_point": Vector2.ZERO})
	_ok("a re-entrant impact is reported once",
		event != null and _hub.damage.impact_count == impacts + 1,
		"%d impacts" % (_hub.damage.impact_count - impacts))
	_ok("the nested attempt is refused, not queued",
		echo.nested_result == null, str(echo.nested_result))
	_ok("the hull is charged for one hit, exactly",
		is_equal_approx(hull_before - _hub.hull_integrity(), 0.2),
		"lost %.2f" % (hull_before - _hub.hull_integrity()))
	_ok("listeners hear one impact, not the echo",
		_count_impacts(_sensor.heard) == before_sensor_impacts + 1,
		"%d heard" % (_count_impacts(_sensor.heard) - before_sensor_impacts))

	_hub.set_energy(100.0)
	_hub.set_energy(NAN)
	_hub.set_energy(INF)
	_hub.add_energy(INF)
	_hub.energy.advance(NAN)
	_hub.energy.advance(INF)
	_ok("NaN and infinity cannot move the reserve",
		is_equal_approx(_hub.energy_charge(), 100.0)
			and is_finite(_hub.energy_ratio()),
		"%.1f units" % _hub.energy_charge())
	var output := _hub.power_output()
	_hub.add_power_source("aux", NAN)
	_ok("a non-finite auxiliary source is ignored",
		is_equal_approx(_hub.power_output(), output)
			and is_finite(_hub.power_granted()))
	_hub.remove_power_source("aux")

	_ok("a non-finite spend is refused",
		not _hub.energy.try_spend(NAN)
			and is_equal_approx(_hub.energy_charge(), 100.0))
	_ok("one spend succeeds", _hub.spend_energy("sensor", 60.0)
		and is_equal_approx(_hub.energy_charge(), 40.0),
		"%.1f units" % _hub.energy_charge())
	_ok("the next cannot spend the same units again",
		not _hub.spend_energy("drill", 60.0)
			and is_equal_approx(_hub.energy_charge(), 40.0),
		"%.1f units" % _hub.energy_charge())

	var added := _hub.add_energy(1000.0)
	_ok("a grant fills the tank and stops at its capacity",
		is_equal_approx(added, 360.0)
			and is_equal_approx(_hub.energy_charge(), _hub.energy_capacity()),
		"+%.1f -> %.1f" % [added, _hub.energy_charge()])
	_hub.set_energy(-5.0)
	_ok("a negative level is clamped to an empty tank",
		is_zero_approx(_hub.energy_charge()) and _hub.is_energy_depleted(),
		"%.2f units" % _hub.energy_charge())
	_hub.set_energy(400.0)
	_ok("and the tank can be restored afterwards",
		is_equal_approx(_hub.energy_charge(), 400.0)
			and not _hub.is_energy_depleted())

	var drill_before := _drill.integrity
	var applied := _hub.apply_damage("drill", 5.0, "arc")
	_ok("damage is clamped to what the device had",
		is_equal_approx(applied, drill_before) and _drill.integrity == 0.0,
		"applied %.2f" % applied)
	_hub.repair("drill", 5.0)
	_ok("repair cannot overflow into a bonus",
		is_equal_approx(_drill.integrity, 1.0), "%.2f" % _drill.integrity)

	var destroyed := _destroyed_events
	var hull := _hub.hull_integrity()
	_ok("a lethal hit applies only what is left",
		is_equal_approx(_hub.apply_hull_damage(hull + 10.0), hull)
			and _hub.hull_integrity() == 0.0
			and _destroyed_events == destroyed + 1,
		"applied %.2f" % hull)
	_hub.repair_hull(999.0)
	echo.queue_free()
	await _steps(1)


## How many IMPACT events a probe heard. A helper rather than a loop in every assertion,
## because "did the bus deliver one event" is the claim those phases actually make.
func _count_impacts(heard: Array) -> int:
	var count := 0
	for event in heard:
		if event.kind == ShipSystemEvent.Kind.IMPACT:
			count += 1
	return count
# --------------------------------------------------------------- 11. panel ----

func _test_panel() -> void:
	print("-- panel")
	var text := "\n".join(_hub.report())
	_ok("the panel prints the reserve", text.contains("reserve"))
	_ok("the panel prints the bus",
		text.contains("power") and text.contains("consumers"))
	_ok("the panel prints the hull", text.contains("hull"))
	_ok("the panel prints the damage router", text.contains("impacts"))
	_ok("the panel prints every device", text.contains("device "))
	_ok("no line carries a non-finite number",
		not text.to_lower().contains("nan"))
	for line in _hub.report():
		print("    " + line)


# ------------------------------------------------------------ 12. teardown ----

func _teardown() -> void:
	print("-- teardown")
	for device in _hub.components():
		device.queue_free()
	await _steps(2)
	_ok("every device leaves the registry", _hub.count() == 0,
		"%d left" % _hub.count())
	_ok("the registry returns empty statuses", _hub.equipment_statuses().is_empty())
	_ok("no device supply is left on the bus",
		is_zero_approx(_hub.energy.device_supply()))
	_hub.set_parameters(_base)
	_hub.repair_hull(999.0)
	await _steps(2)
	_ok("the hull is whole for the next suite",
		is_equal_approx(_hub.hull_ratio(), 1.0), "%.2f" % _hub.hull_ratio())
	_ok("the reserve is inside its tank",
		_hub.energy_charge() >= 0.0
			and _hub.energy_charge() <= _hub.energy_capacity() + 0.001
			and is_finite(_hub.energy_ratio()),
		"%.1f / %.1f" % [_hub.energy_charge(), _hub.energy_capacity()])
	quit(1 if _failed else 0)