extends SceneTree

## Sub-stage 4.1 verification: the ship's internal systems architecture.
## Run: godot --headless --path . --script tests/ship_systems_test.gd
##
## What this suite is built to hold, in the order the phases run:
##
## 1. **The hull is untouched.** `Ship.tscn` gained one child node; the flight model,
##    the engine plant and the three assists must fly exactly as before. The first
##    phase burns the main engine and checks the speed and power the 1.1/1.2 suites
##    already pin down, because an architecture that quietly re-tunes the ship is the
##    one failure a "no behaviour change" stage can have.
## 2. **Mounting is installation.** A device added to the tree registers itself, lands
##    on the power bus and gets a derived state with no call from the test beyond
##    `add_child()`.
## 3. **Power is shared by priority and by nothing else.** A budget too small for
##    everyone starves the lowest priority first, the starved device says so in its own
##    state, and switching one device off gives another its power back.
## 4. **The three states are derived, not declared.** Integrity and the crew switch are
##    the only inputs; NOMINAL -> DAMAGED -> OFFLINE happens where the thresholds say,
##    and a wreck stops drawing power without anybody telling the bus.
## 5. **Events travel.** A device publishes in its own words, another device hears it,
##    and an impact from the flight model arrives as one classified event.
## 6. **Nothing here steps the frame.** The hub has no `_process`/`_physics_process`,
##    and the tree does not grow while it runs.
##
## The suite prints a PASS/FAIL line per claim and ends with `RESULT: ALL PASS`, which
## is what `tools/testing/run_tests.ps1` reads.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: ShipController
var _hub: ShipSystems
var _base: ShipSystemsParameters

var _events: Array[ShipSystemEvent] = []
var _state_events := 0
var _hull_state_events := 0
var _hull_ratio_events := 0
var _registered := 0
var _unregistered := 0

var _sensor: Probe
var _drill: Probe
var _railgun: Probe
var _rock: RigidBody2D


## A device that does nothing except remember what it was told. Everything the suite
## needs to know about the bus is observable from here, which is the point: a test
## should not have to reach into the hub to prove that a message arrived.
class Probe extends ShipComponent:
	var heard: Array = []
	var history: Array = []

	func receive_event(event: ShipSystemEvent) -> void:
		heard.append(event)

	func _on_state(previous: int, current: int) -> void:
		history.append([previous, current])


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
	_hub.system_event.connect(_on_event)
	_hub.system_state_changed.connect(_on_state_changed)
	_hub.hull_state_changed.connect(_on_hull_state_changed)
	_hub.hull_integrity_changed.connect(_on_hull_ratio_changed)
	_hub.component_registered.connect(_on_registered)
	_hub.component_unregistered.connect(_on_unregistered)
	await _steps(3)

	_test_boot()
	await _test_flight_unchanged()
	await _test_equipment()
	await _test_power()
	await _test_integrity()
	await _test_bus()
	await _test_impact()
	_test_panel()
	await _restore()

	print("")
	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


func _on_event(event: ShipSystemEvent) -> void:
	_events.append(event)


func _on_state_changed(_id: String, _previous: int, _current: int) -> void:
	_state_events += 1


func _on_hull_state_changed(_previous: int, _current: int) -> void:
	_hull_state_events += 1


func _on_hull_ratio_changed(_ratio: float) -> void:
	_hull_ratio_events += 1


func _on_registered(_component: ShipComponent) -> void:
	_registered += 1


func _on_unregistered(_component: ShipComponent) -> void:
	_unregistered += 1


## A device built by the test: identity, appetite, and a place to keep what it heard.
func _probe(id: String, draw: float, priority: int) -> Probe:
	var device := Probe.new()
	device.name = id.capitalize().replace(" ", "")
	device.component_id = id
	device.nominal_power_draw = draw
	device.power_priority = priority
	device.state_changed.connect(device._on_state)
	_hub.add_child(device)
	return device



# ---------------------------------------------------------------- 1. the boot ---

func _test_boot() -> void:
	print("-- boot")
	_ok("Ship.tscn carries a systems hub", _hub is ShipSystems)
	_ok("the hub is a child of the hull", _hub.get_parent() == _ship)
	_ok("the hub owns the energy system", _hub.energy != null)
	_ok("the hub owns the health system", _hub.health != null)
	_ok("the hub owns the damage router", _hub.damage != null)
	_ok("the tuning resource came from the scene", _hub.parameters != null,
		String(_hub.parameters.resource_path))
	_ok("a fresh hull mounts no devices", _hub.count() == 0,
		"%d mounted" % _hub.count())
	_ok("a fresh hull is nominal", _hub.state() == ShipSystemState.Value.NOMINAL,
		_hub.state_name())
	_ok("the hull starts whole", is_equal_approx(_hub.hull_ratio(), 1.0),
		"%.2f" % _hub.hull_ratio())
	_ok("the hub has no per-frame step",
		not _hub.has_method("_process") and not _hub.has_method("_physics_process"))
	_ok("the hub listens to the flight model's contact report",
		_ship.is_connected("ship_collision_detected",
			Callable(_hub, "_on_ship_collision")))
	_ok("the damage router can classify against the ship's own bands",
		_hub.damage.world == _ship.world)
	_ok("the layer does not touch the plant",
		_ship.engines.main_power == 0.0 and _ship.engines.brake_power == 0.0,
		"main %.2f" % _ship.engines.main_power)


# ------------------------------------- 2. the flight model still flies the ship ---

## The one claim this whole sub-stage can break and still pass every other test: the
## hull must fly exactly as it did before a systems layer existed. The numbers below
## are the ones `stage1_2_engines_test` and `stage1_control_test` already hold the
## flight model to - the engine reaches full authority on its own ramp and the speed
## climbs along the nose.
func _test_flight_unchanged() -> void:
	print("-- flight unchanged")
	var start := _ship.speed()
	Input.action_press("thrust_forward")
	await _steps(45)
	var power := _ship.engines.main_power
	var speed := _ship.speed()
	Input.action_release("thrust_forward")
	_ok("the main engine still reaches full authority", power > 0.98, "%.2f" % power)
	_ok("the hull still accelerates", speed > start + 200.0,
		"%.0f -> %.0f px/s" % [start, speed])
	_ok("the hull still flies along its nose", absf(_ship.drift_speed()) < 25.0,
		"drift %.2f px/s" % _ship.drift_speed())
	_ok("the burn did not hurt the hull", is_equal_approx(_hub.hull_ratio(), 1.0),
		"%.2f" % _hub.hull_ratio())
	_ok("the burn was not reported as an impact", _hub.damage.impact_count == 0)
	# Let the plant wind down and park the hull by hand, so the next phase starts from
	# a known state instead of from whatever the drag left behind.
	await _steps(40)
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	await _steps(2)
	_ok("the plant winds down with no keys held", _ship.engines.main_power < 0.05,
		"%.3f" % _ship.engines.main_power)
# --------------------------------------------------- 3. equipment on the bus ----

## Mounting is installation: no call into the hub, no registration list, no change to
## the ship's code. The devices below are added with `add_child()` and are on the bus
## before the call returns.
func _test_equipment() -> void:
	print("-- equipment")
	_sensor = _probe("sensor", 40.0, 10)
	_drill = _probe("drill", 60.0, 5)
	_ok("a mounted device joins the registry", _hub.count() == 2,
		", ".join(_hub.component_ids()))
	_ok("the hub reported both mounts", _registered == 2, "%d events" % _registered)
	_ok("a mounted device finds its hub", _sensor.systems == _hub and _drill.systems == _hub)
	_ok("the registry resolves by id", _hub.component("sensor") == _sensor)
	_ok("a mounted device is nominal", _sensor.state == ShipSystemState.Value.NOMINAL
		and _drill.state == ShipSystemState.Value.NOMINAL,
		_sensor.status_line() + " | " + _drill.status_line())
	_ok("a nominal device uses its full capability",
		is_equal_approx(_sensor.efficiency(), 1.0), "%.2f" % _sensor.efficiency())
	_ok("both appetites reached the bus", is_equal_approx(_hub.power_demand(), 100.0),
		"%.1f units" % _hub.power_demand())
	_ok("a comfortable reactor leaves nobody short", not _hub.is_brownout(),
		"%.1f / %.1f" % [_hub.power_granted(), _hub.power_output()])

	# One switch, one device. The other keeps its grant and its state.
	_ok("a switch can be thrown by id", _hub.set_enabled("drill", false))
	_ok("the switched device goes offline",
		_drill.state == ShipSystemState.Value.OFFLINE, _drill.status_line())
	_ok("its neighbour is untouched",
		_sensor.state == ShipSystemState.Value.NOMINAL and is_equal_approx(_sensor.power_ratio, 1.0))
	_ok("a switched-off device stops drawing", is_equal_approx(_hub.power_demand(), 40.0),
		"%.1f units" % _hub.power_demand())
	_ok("an unknown id is refused rather than guessed", _hub.set_enabled("nobody", true) == false)

	_ok("the switch is a switch, not a one-way door", _hub.set_enabled("drill", true))
	_ok("the device comes back nominal",
		_drill.state == ShipSystemState.Value.NOMINAL, _drill.status_line())
	_ok("its appetite is back on the bus", is_equal_approx(_hub.power_demand(), 100.0),
		"%.1f units" % _hub.power_demand())
	_ok("the switch moves were reported", _state_events > 0, "%d state events" % _state_events)

	# Two devices behind one id would be a mystery power draw; the hub refuses the
	# second and keeps serving the first.
	var clash := Probe.new()
	clash.component_id = "sensor"
	_ok("a duplicate id is refused", _hub.register_component(clash) == false)
	_ok("the original keeps the id", _hub.component("sensor") == _sensor)
	clash.free()


# ------------------------------------------------------ 4. sharing the budget ----

## Priority decides, the budget decides, and nothing else does. Each starved device
## says so in its own state - which is the whole reason the grant is written into the
## device instead of being kept as a number inside the energy system.
func _test_power() -> void:
	print("-- power")
	var tight := ShipSystemsParameters.new()
	tight.reactor_output = 100.0
	_hub.set_parameters(tight)
	_ok("a budget that fits everyone leaves everyone whole",
		not _hub.is_brownout()
			and is_equal_approx(_sensor.power_ratio, 1.0)
			and is_equal_approx(_drill.power_ratio, 1.0),
		"%s | %s" % [_sensor.status_line(), _drill.status_line()])

	# A greedy, high-priority device arrives and takes its 60 units first.
	_railgun = _probe("railgun", 60.0, 20)
	_ok("the highest priority is served first",
		is_equal_approx(_railgun.power_ratio, 1.0), _railgun.status_line())
	_ok("the middle device keeps its full grant",
		is_equal_approx(_sensor.power_ratio, 1.0), _sensor.status_line())
	_ok("the lowest priority is cut off",
		_drill.state == ShipSystemState.Value.OFFLINE
			and is_equal_approx(_drill.power_ratio, 0.0), _drill.status_line())
	_ok("a starved device offers no capability",
		is_equal_approx(_drill.efficiency(), 0.0), "%.2f" % _drill.efficiency())
	_ok("the bus says it is short", _hub.is_brownout(),
		"%.1f / %.1f units" % [_hub.power_granted(), _hub.power_output()])
	_ok("a starved device still asks the bus for its power",
		is_equal_approx(_hub.power_demand(), 160.0), "%.1f units" % _hub.power_demand())
	_ok("a device cut off by the bus is granted nothing",
		is_equal_approx(float(_hub.energy.last_allocation.get("drill", -1.0)), 0.0),
		"grant %.2f" % float(_hub.energy.last_allocation.get("drill", -1.0)))

	# An auxiliary source brings the cut-off device back without touching a priority.
	_hub.add_power_source("aux", 100.0)
	_ok("an auxiliary source restores the budget",
		not _hub.is_brownout() and _drill.state == ShipSystemState.Value.NOMINAL,
		"%.1f units" % _hub.power_output())
	_ok("and everyone is whole again",
		is_equal_approx(_drill.power_ratio, 1.0) and is_equal_approx(_sensor.power_ratio, 1.0))
	_hub.remove_power_source("aux")
	_ok("removing the source takes the budget away again",
		_hub.is_brownout() and _drill.state == ShipSystemState.Value.OFFLINE)

	# Independent disconnection: switching the greedy device off gives the budget back
	# to the devices it was starving.
	_hub.set_enabled("railgun", false)
	_ok("a disconnected device frees its share",
		not _hub.is_brownout()
			and _drill.state == ShipSystemState.Value.NOMINAL
			and is_equal_approx(_sensor.power_ratio, 1.0),
		"%s | %s" % [_sensor.status_line(), _drill.status_line()])

	# A partial grant is a state of its own: not nominal, not off.
	tight.reactor_output = 70.0
	_hub.set_enabled("railgun", true)
	_hub.set_parameters(tight)
	_ok("a partial grant reads as damaged",
		_sensor.state == ShipSystemState.Value.DAMAGED, _sensor.status_line())
	_ok("the partial grant is arithmetic, not a guess",
		is_equal_approx(_sensor.power_ratio, 0.25), "%.2f" % _sensor.power_ratio)
	_ok("a damaged device runs at reduced capability",
		is_equal_approx(_sensor.efficiency(), 0.5), "%.2f" % _sensor.efficiency())
	_ok("the bus still reports the shortfall", _hub.is_brownout())

	_hub.set_parameters(_base)
	_railgun.queue_free()
	_railgun = null
	await _steps(2)
	_ok("a freed device leaves the registry", _hub.count() == 2,
		", ".join(_hub.component_ids()))
	_ok("a freed device leaves the bus", _unregistered >= 1,
		"%d unregister events" % _unregistered)
	_ok("the budget recovers on its own", not _hub.is_brownout()
			and _sensor.state == ShipSystemState.Value.NOMINAL
			and _drill.state == ShipSystemState.Value.NOMINAL,
		"%s | %s" % [_sensor.status_line(), _drill.status_line()])


# ----------------------------------------------- 5. condition and integrity ----

## The three states are derived, never declared: the switch, the integrity and the
## grant are the only inputs, and the device cannot argue with any of them.
func _test_integrity() -> void:
	print("-- condition")
	_ok("damage lands on the device, not on a copy",
		is_equal_approx(_hub.apply_damage("sensor", 0.45), 0.45)
			and is_equal_approx(_sensor.integrity, 0.55),
		_sensor.status_line())
	_ok("a hurt device is damaged, not dead",
		_sensor.state == ShipSystemState.Value.DAMAGED, _sensor.status_line())
	_ok("a damaged device still draws its full appetite",
		is_equal_approx(_hub.power_demand(), 100.0), "%.1f units" % _hub.power_demand())
	_ok("a damaged device is still on the ship", _sensor.is_operational())

	_hub.apply_damage("sensor", 0.45)
	_ok("a wrecked device goes offline",
		_sensor.state == ShipSystemState.Value.OFFLINE, _sensor.status_line())
	_ok("a wrecked device stops drawing power on its own",
		is_equal_approx(_hub.power_demand(), 60.0), "%.1f units" % _hub.power_demand())
	_ok("a wrecked device offers no capability",
		is_equal_approx(_sensor.efficiency(), 0.0))

	_hub.repair("sensor", 0.55)
	_ok("repair brings the device back through the same rule",
		_sensor.state == ShipSystemState.Value.NOMINAL
			and is_equal_approx(_sensor.integrity, 0.65), _sensor.status_line())

	# The return value is what was actually taken, not what was asked for: a caller
	# that sums the returns gets the truth about the damage it caused.
	var overkill := _hub.apply_damage("sensor", 5.0)
	_ok("damage is clamped to what is left", is_equal_approx(overkill, 0.65),
		"applied %.2f" % overkill)
	_ok("nothing goes below zero", is_equal_approx(_sensor.integrity, 0.0),
		"%.2f" % _sensor.integrity)
	var overrepair := _hub.repair("sensor", 5.0)
	_ok("repair never overfills", is_equal_approx(overrepair, 1.0)
		and is_equal_approx(_sensor.integrity, 1.0), "applied %.2f" % overrepair)
	_ok("a repaired device reads nominal again",
		_sensor.state == ShipSystemState.Value.NOMINAL, _sensor.status_line())

	# The hull has its own ledger, and its own two threshold crossings.
	_hub.apply_hull_damage(0.5, "test")
	_ok("the hull keeps its own integrity",
		is_equal_approx(_hub.hull_ratio(), 0.5), "%.2f" % _hub.hull_ratio())
	_ok("the hull crosses into damaged",
		_hub.hull_state() == ShipSystemState.Value.DAMAGED,
		ShipSystemState.name_of(_hub.hull_state()))
	_ok("the hull change was signalled", _hull_state_events > 0 and _hull_ratio_events > 0,
		"%d state / %d ratio" % [_hull_state_events, _hull_ratio_events])
	_hub.apply_hull_damage(0.4, "test")
	_ok("the hull crosses into offline",
		_hub.hull_state() == ShipSystemState.Value.OFFLINE,
		ShipSystemState.name_of(_hub.hull_state()))
	_ok("the ship is as bad as its worst part",
		_hub.state() == ShipSystemState.Value.OFFLINE, _hub.state_name())
	_hub.repair_hull(1.0)
	_ok("the hull can be made whole again",
		is_equal_approx(_hub.hull_ratio(), 1.0)
			and _hub.state() == ShipSystemState.Value.NOMINAL, _hub.state_name())

	# A hull-level aggregate is the worst device when the hull itself is fine.
	_hub.apply_damage("drill", 0.5)
	_ok("a damaged device alone makes the ship read as damaged",
		_hub.state() == ShipSystemState.Value.DAMAGED
			and _hub.hull_state() == ShipSystemState.Value.NOMINAL, _hub.state_name())
	_hub.repair("drill", 1.0)
	_ok("repairing it returns the ship to nominal",
		_hub.state() == ShipSystemState.Value.NOMINAL, _hub.state_name())


# ---------------------------------------------------------------- 6. the bus ----

## A device says something in its own words and every other device hears it. No
## device holds a reference to another one; the hub is the only thing between them.
func _test_bus() -> void:
	print("-- bus")
	_sensor.heard.clear()
	_drill.heard.clear()
	var before := _events.size()
	_sensor.publish("ping", {"n": 1})
	_ok("a device can speak on the bus",
		_sensor.heard.size() == 1 and _drill.heard.size() == 1,
		"%d / %d heard" % [_sensor.heard.size(), _drill.heard.size()])
	var heard: ShipSystemEvent = _drill.heard[0]
	_ok("the event carries the producer's id and topic",
		heard.kind == ShipSystemEvent.Kind.EQUIPMENT and heard.component_id == "sensor"
			and String(heard.data.get("topic", "")) == "ping", heard.describe())
	_ok("the payload survives the trip", int(heard.data.get("n", 0)) == 1)
	_ok("the hub re-broadcast it", _events.size() == before + 1)

	_hub.dispatch(ShipSystemEvent.custom("drill", "hello", {"text": "x"}))
	_ok("a custom event reaches every device",
		_drill.heard.size() == 2 and _sensor.heard.size() == 2)
	_ok("a device keeps its own words",
		String((_sensor.heard[1] as ShipSystemEvent).data.get("topic", "")) == "hello")
	_ok("every event is on the hub's own signal", _events.size() == before + 2)
	_ok("events are timestamped on the physics clock",
		(_sensor.heard[0] as ShipSystemEvent).at >= 0.0,
		"%.2f s" % (_sensor.heard[0] as ShipSystemEvent).at)


# ------------------------------------------------ 7. the world touches the hull ---

## The flight model has reported classified contacts since 1.4; this phase proves the
## new layer reads that report without the controller knowing it exists. A real rock
## is flown into on purpose, and then a synthetic report exercises the damage seam
## with the switch turned on.
func _test_impact() -> void:
	print("-- impact")
	_ship.global_position = Vector2.ZERO
	_ship.rotation = 0.0
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	# The shipped resource damages on contact as of stage 4.3. This phase still has to
	# prove the off-switch path, so it turns the switch off explicitly rather than
	# relying on a default that no longer exists.
	var calm := ShipSystemsParameters.new()
	calm.impact_damage_enabled = false
	_hub.set_parameters(calm)
	_hub.repair_hull(10.0)
	_rock = ROCK_SCENE.instantiate()
	_rock.set("shape", "04")
	_rock.set("px_scale", 2.0)
	_root.add_child(_rock)
	_rock.global_position = Vector2(700.0, 0.0)
	_rock.linear_velocity = Vector2.ZERO
	await _steps(2)

	var before := _hub.damage.impact_count
	var events_before := _events.size()
	_ship.linear_velocity = Vector2(650.0, 0.0)
	var waited := 0
	while _hub.damage.impact_count == before and waited < 150:
		await physics_frame
		waited += 1
	_ok("a real contact reaches the systems layer", _hub.damage.impact_count > before,
		"after %d frames" % waited)
	var severity := String(_hub.damage.last_impact.get("severity", ""))
	_ok("the impact was classified", ["LIGHT", "MEDIUM", "HEAVY"].has(severity), severity)
	_ok("the impact carries the closing speed",
		float(_hub.damage.last_impact.get("closing_speed", 0.0)) > 45.0,
		"%.0f px/s" % float(_hub.damage.last_impact.get("closing_speed", 0.0)))
	var impact_events := 0
	for event in _events.slice(events_before):
		if event.kind == ShipSystemEvent.Kind.IMPACT:
			impact_events += 1
	_ok("the hit arrived as an event per report", impact_events >= 1,
		"%d events" % impact_events)
	_ok("routing an impact costs nothing while the switch is off",
		is_equal_approx(_hub.hull_ratio(), 1.0), "%.2f" % _hub.hull_ratio())

	# The damage seam: switch it on and the same path spends integrity. No full damage
	# model here - one number per band, which is exactly what the next sub-stage
	# replaces.
	var armed := ShipSystemsParameters.new()
	armed.impact_damage_enabled = true
	armed.light_impact_damage = 0.02
	armed.medium_impact_damage = 0.1
	armed.heavy_impact_damage = 0.2
	_hub.set_parameters(armed)
	var event := _hub.report_impact({
		"closing_speed": 600.0,
		"category": "HEAVY",
		"description": {"kind": "asteroid", "label": "synthetic"},
	})
	_ok("a reported impact keeps its band",
		String(event.data.get("severity", "")) == "HEAVY", event.describe())
	_ok("the impact event carries its cost",
		is_equal_approx(float(event.data.get("hull_damage", 0.0)), 0.2),
		"%.2f" % float(event.data.get("hull_damage", 0.0)))
	_ok("the hull paid for it", is_equal_approx(_hub.hull_ratio(), 0.8),
		"%.2f" % _hub.hull_ratio())
	_ok("the wound arrived as its own event",
		_events[-1].kind == ShipSystemEvent.Kind.DAMAGE_TAKEN, _events[-1].describe())

	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	if _rock != null and is_instance_valid(_rock):
		_rock.queue_free()
		_rock = null
	_hub.set_parameters(_base)
	_hub.repair_hull(1.0)
	await _steps(2)


# --------------------------------------------------------------- 8. the panel ----

func _test_panel() -> void:
	print("-- panel")
	var lines := _hub.report()
	var text := "\n".join(lines)
	_ok("the panel has a line per responsibility", lines.size() >= 5,
		"%d lines" % lines.size())
	_ok("the panel prints the bus, the hull, the impacts and the devices",
		text.contains("power") and text.contains("hull")
			and text.contains("impacts") and text.contains("device"))
	for line in lines:
		print("    " + line)


# ------------------------------------------------------------- 9. the takedown ---

## Nothing the suite mounted may outlive it, and the layer must not have grown the
## ship's tree while it ran: one static child node is the whole of what this stage
## adds to `Ship.tscn`.
func _restore() -> void:
	print("-- restore")
	for device in _hub.components():
		device.queue_free()
	await _steps(2)
	_ok("the hull returns to no devices", _hub.count() == 0,
		"%d left" % _hub.count())
	_hub.set_parameters(_base)
	_hub.repair_hull(10.0)
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	var children := _ship.get_child_count()
	await _steps(30)
	_ok("the layer does not grow the ship's tree", _ship.get_child_count() == children,
		"%d children" % _ship.get_child_count())
	_ok("nothing is left holding the hull open",
		is_equal_approx(_hub.hull_ratio(), 1.0) and not _hub.is_brownout(),
		_hub.state_name())

