extends SceneTree

## Sub-stage 4.2 verification: the ship's energy reserve.
## Run: godot --headless --path . --script tests/ship_energy_test.gd
##
## The reserve sits under the bus built in 4.1: `ShipEnergySystem` still decides who
## gets power, and now also pays for it from a tank with a capacity, a regeneration
## rate and two alarm lines. This suite holds that contract in nine phases:
##
## 1. boot: the tank exists, starts full, and an idle hull neither drains nor overfills;
## 2. consumption: one second of load costs exactly one second of charge, once;
## 3. regeneration: the tank refills, clamps at capacity, and a dock cannot overfill it;
## 4. bounds: charge is never negative, a refused spend changes nothing, and a spend
##    can never take more than the tank holds;
## 5. activation: a device with a switch-on cost is checked before it lights, pays once,
##    and an already-lit device is not charged a second time;
## 6. blackout: the low alarm fires once per crossing, the tank stops at zero, the bus
##    goes dark, every device is cut off, and the restart line prevents flapping;
## 7. extensibility: a device mounted after all of that is powered by the same code;
## 8. the clock: the per-frame node actually spends the reserve in a live tree;
## 9. report and teardown.
##
## Every phase disables the clock and calls `advance()` by hand, so the arithmetic is
## exact. Phase 8 turns the clock back on - that is the only place real frames are
## trusted to move the tank.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: ShipController
var _hub: ShipSystems
var _base: ShipSystemsParameters

var _changed := 0
var _lows := 0
var _drained := 0
var _restarts := 0
var _refusals := 0

var _sensor: Probe
var _railgun: Probe


## A device that does nothing except exist on the bus. That is the point of the test:
## the energy system must serve it without the device knowing a reserve exists.
class Probe extends ShipComponent:
	pass


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


func _on_changed(_ratio: float, _charge: float, _capacity: float) -> void:
	_changed += 1


func _on_low(_ratio: float) -> void:
	_lows += 1


func _on_depleted() -> void:
	_drained += 1


func _on_restored() -> void:
	_restarts += 1


func _on_refused(_id: String, _cost: float, _available: float) -> void:
	_refusals += 1


## A tuning resource with the reserve numbers this phase needs. A fresh resource each
## time, so no phase inherits a capacity or a rate from the one before it.
func _fresh(capacity: float, recharge: float, low := 0.25, restart := 0.1) -> void:
	var p := ShipSystemsParameters.new()
	p.energy_capacity = capacity
	p.energy_recharge_rate = recharge
	p.energy_low_ratio = low
	p.energy_restart_ratio = restart
	_hub.set_parameters(p)


## Mount a device the way a scene author would: set the exports, add the node.
func _probe(id: String, draw: float, priority: int, cost := 0.0,
		start := true) -> Probe:
	var device := Probe.new()
	device.name = id.capitalize()
	device.component_id = id
	device.nominal_power_draw = draw
	device.power_priority = priority
	device.activation_energy_cost = cost
	device.starts_enabled = start
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
	_hub.energy_changed.connect(_on_changed)
	_hub.energy_low.connect(_on_low)
	_hub.energy_depleted.connect(_on_depleted)
	_hub.energy_restored.connect(_on_restored)
	_hub.activation_refused.connect(_on_refused)
	await _steps(3)

	_test_boot()
	_test_consumption()
	_test_regeneration()
	_test_bounds()
	_test_activation()
	_test_blackout()
	_test_new_device()
	await _test_clock()
	_test_report()
	await _teardown()

	print("")
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED %d of %d" % [_failed, _checks])
	quit(1 if _failed else 0)


# ---------------------------------------------------------------- 1. the boot ---

func _test_boot() -> void:
	print("-- boot")
	_ok("the hub owns an energy system", _hub.energy != null)
	_ok("the hull carries a reserve", _hub.energy.has_reserve(),
		"%.0f units" % _hub.energy_capacity())
	_ok("the tank starts full",
		is_equal_approx(_hub.energy_charge(), _hub.energy_capacity()),
		"%.1f / %.1f" % [_hub.energy_charge(), _hub.energy_capacity()])
	_ok("a full tank reads 1.0", is_equal_approx(_hub.energy_ratio(), 1.0),
		"%.2f" % _hub.energy_ratio())
	_ok("the reserve does not start alarmed",
		not _hub.is_energy_low() and not _hub.is_energy_depleted())
	_ok("the reserve has its own clock node",
		_hub.clock != null and _hub.clock.energy == _hub.energy)
	_ok("the hub itself still has no per-frame step",
		not _hub.has_method("_physics_process"), "ShipEnergyClock ticks instead")
	_hub.clock.set_physics_process(false)
	var before := _hub.energy_charge()
	_hub.energy.advance(1.0)
	_ok("an idle hull neither drains nor overfills",
		is_equal_approx(_hub.energy_charge(), before),
		"%.1f -> %.1f" % [before, _hub.energy_charge()])


# ----------------------------------------------------------- 2. it gets spent ---

func _test_consumption() -> void:
	print("-- consumption")
	_fresh(200.0, 0.0)
	_hub.set_energy(200.0)
	_sensor = _probe("sensor", 50.0, 10)
	_ok("a mounted device's appetite reaches the bus",
		is_equal_approx(_hub.power_demand(), 50.0), "%.1f units" % _hub.power_demand())
	_ok("a full reserve pays it in full",
		is_equal_approx(_hub.power_granted(), 50.0), "%.1f units" % _hub.power_granted())

	_hub.energy.advance(1.0)
	_ok("one second of load costs one second of charge",
		is_equal_approx(_hub.energy_charge(), 150.0), "%.1f units" % _hub.energy_charge())
	_hub.energy.advance(1.0)
	_ok("the next second is paid once, not charged twice for the first",
		is_equal_approx(_hub.energy_charge(), 100.0), "%.1f units" % _hub.energy_charge())
	_ok("the level follows the tank", is_equal_approx(_hub.energy_ratio(), 0.5),
		"%.2f" % _hub.energy_ratio())
	_ok("the net rate says the hull is living off the tank",
		is_equal_approx(_hub.energy.net_rate(), -50.0),
		"%.1f /s" % _hub.energy.net_rate())

	# A starved device asks for 50 and gets 30. The tank pays 30: the ship is charged
	# for what it used, not for what it wanted.
	var tight := ShipSystemsParameters.new()
	tight.energy_capacity = 200.0
	tight.energy_recharge_rate = 0.0
	tight.reactor_output = 30.0
	_hub.set_parameters(tight)
	_hub.set_energy(100.0)
	_hub.energy.advance(1.0)
	_ok("a brownout pays for the grant, not the demand",
		is_equal_approx(_hub.energy_charge(), 70.0) and _hub.is_brownout(),
		"%.1f units, granted %.1f of %.1f" % [_hub.energy_charge(),
			_hub.power_granted(), _hub.power_demand()])


# ------------------------------------------------------------ 3. it refills -----

func _test_regeneration() -> void:
	print("-- regeneration")
	_hub.set_enabled("sensor", false)
	_ok("a switched-off device stops costing energy",
		is_equal_approx(_hub.power_granted(), 0.0), "%.1f units" % _hub.power_granted())

	_fresh(200.0, 20.0)
	_hub.set_energy(10.0)
	_hub.energy.advance(1.0)
	_ok("the reserve regenerates at its rate",
		is_equal_approx(_hub.energy_charge(), 30.0), "%.1f units" % _hub.energy_charge())
	_hub.energy.advance(100.0)
	_ok("regeneration never overfills the tank",
		is_equal_approx(_hub.energy_charge(), 200.0), "%.1f units" % _hub.energy_charge())
	_ok("a dock cannot pour past capacity",
		is_equal_approx(_hub.add_energy(50.0), 0.0)
			and is_equal_approx(_hub.energy_charge(), 200.0))
	_hub.set_enabled("sensor", true)
	_ok("a device with no switch-on cost still lights", _sensor.enabled)


# -------------------------------------------------------------- 4. the bounds ---

func _test_bounds() -> void:
	print("-- bounds")
	_hub.set_enabled("sensor", false)
	_hub.set_energy(-5.0)
	_ok("charge never goes below zero",
		is_equal_approx(_hub.energy_charge(), 0.0), "%.1f" % _hub.energy_charge())
	_ok("an empty tank is latched", _hub.is_energy_depleted())
	_ok("an empty tank cannot afford a cost", not _hub.energy.can_afford(10.0))
	var before := _hub.energy_charge()
	_ok("a refused spend changes nothing",
		not _hub.energy.try_spend(10.0)
			and is_equal_approx(_hub.energy_charge(), before),
		"%.1f" % _hub.energy_charge())

	_hub.set_energy(200.0)
	_ok("try_spend takes exactly the amount",
		_hub.energy.try_spend(150.0) and is_equal_approx(_hub.energy_charge(), 50.0),
		"%.1f" % _hub.energy_charge())
	_ok("a spend larger than the tank is refused whole",
		not _hub.energy.try_spend(100.0)
			and is_equal_approx(_hub.energy_charge(), 50.0),
		"%.1f" % _hub.energy_charge())
	_ok("spending the last unit empties the tank",
		_hub.energy.try_spend(50.0)
			and is_equal_approx(_hub.energy_charge(), 0.0)
			and _hub.is_energy_depleted())


# ----------------------------------------------------------- 5. switch-on cost ---

## A device with an appetite is one thing; a device that costs a surge to light is
## another. This phase holds the second: the check is asked before the switch moves,
## the cost is paid once, and a refusal spends nothing and leaves the device off.
func _test_activation() -> void:
	print("-- activation")
	_railgun = _probe("railgun", 20.0, 20, 40.0, false)
	_ok("a device can ship switched off", not _railgun.enabled)
	_fresh(200.0, 0.0)
	_hub.set_energy(100.0)
	_ok("the switch-on cost is read off the device",
		is_equal_approx(_railgun.activation_energy_cost, 40.0),
		"%.0f units" % _railgun.activation_energy_cost)
	_ok("the check spends nothing",
		_hub.can_activate("railgun")
			and is_equal_approx(_hub.energy_charge(), 100.0))
	var refusals := _refusals
	_ok("activation pays the cost once",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 60.0),
		"%.1f" % _hub.energy_charge())
	_ok("the device is lit and drawing",
		_railgun.enabled and is_equal_approx(_hub.power_demand(), 20.0),
		"%.1f units" % _hub.power_demand())
	_ok("a second press on a lit device costs nothing",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 60.0),
		"%.1f" % _hub.energy_charge())

	_hub.set_enabled("railgun", false)
	_hub.set_energy(30.0)
	_ok("a short reserve refuses the check", not _hub.can_activate("railgun"))
	_ok("a refused switch does not move",
		not _hub.set_enabled("railgun", true) and not _railgun.enabled)
	_ok("a refused switch spends nothing",
		is_equal_approx(_hub.energy_charge(), 30.0), "%.1f" % _hub.energy_charge())
	_ok("the refusal was signalled", _refusals == refusals + 1,
		"%d refusals" % _refusals)
	_hub.set_energy(100.0)
	_ok("a funded switch works",
		_hub.set_enabled("railgun", true)
			and is_equal_approx(_hub.energy_charge(), 60.0),
		"%.1f" % _hub.energy_charge())


# ------------------------------------------------------------ 6. the blackout ---

## The end of the line: low alarm, empty tank, dark bus, and a restart that waits for
## the restart line instead of flickering on the first regenerated unit.
func _test_blackout() -> void:
	print("-- blackout")
	_fresh(100.0, 0.0, 0.25, 0.1)
	_hub.set_energy(30.0)
	var lows := _lows
	_hub.energy.advance(0.2)
	_ok("a healthy reserve raises no alarm",
		_lows == lows and not _hub.is_energy_low(),
		"%.0f%%" % (_hub.energy_ratio() * 100.0))
	_hub.energy.advance(0.5)
	_ok("crossing the low line raises one alarm",
		_lows == lows + 1 and _hub.is_energy_low(),
		"%.0f%%" % (_hub.energy_ratio() * 100.0))

	var drain := _drained
	_hub.energy.advance(1.0)
	_ok("the tank stops at exactly zero",
		is_equal_approx(_hub.energy_charge(), 0.0), "%.2f" % _hub.energy_charge())
	_ok("blackout is reported once", _drained == drain + 1,
		"%d event(s)" % (_drained - drain))
	_ok("the bus goes dark",
		is_zero_approx(_hub.power_output()) and _hub.is_brownout())
	_ok("the device is cut off",
		_railgun.state == ShipSystemState.Value.OFFLINE
			and is_equal_approx(_railgun.power_ratio, 0.0),
		_railgun.status_line())
	_hub.energy.advance(5.0)
	_ok("a dark tank never goes negative",
		is_equal_approx(_hub.energy_charge(), 0.0), "%.2f" % _hub.energy_charge())

	# A live reactor does not restore the bus until the restart line is crossed.
	_fresh(100.0, 20.0, 0.25, 0.1)
	_ok("a blackout is latched, not a single frame", _hub.is_energy_depleted())
	var restarts := _restarts
	_hub.energy.advance(0.4)
	_ok("the bus stays dark below the restart line",
		_hub.is_energy_depleted() and is_zero_approx(_hub.power_output()),
		"%.1f units" % _hub.energy_charge())
	_ok("no restart was reported yet", _restarts == restarts)
	_hub.energy.advance(0.2)
	_ok("the bus restarts above the restart line",
		not _hub.is_energy_depleted() and _hub.power_output() > 0.0,
		"%.1f units" % _hub.energy_charge())
	_ok("the restart was reported once", _restarts == restarts + 1)
	_ok("the device is powered again",
		_railgun.state == ShipSystemState.Value.NOMINAL, _railgun.status_line())


# ------------------------------------------------------- 7. a new device joins ---

## The requirement that keeps the energy system from becoming a list of special cases:
## a device that did not exist when this file was written is served by the same code.
func _test_new_device() -> void:
	print("-- new device")
	_probe("drill", 30.0, 5, 10.0, false)
	_ok("a device mounted later joins the same bus",
		_hub.has_component("drill") and _hub.count() == 3,
		", ".join(_hub.component_ids()))
	_hub.set_energy(50.0)
	_ok("its switch-on cost comes from the same tank",
		_hub.set_enabled("drill", true)
			and is_equal_approx(_hub.energy_charge(), 40.0),
		"%.1f" % _hub.energy_charge())
	_ok("its appetite is added to the same demand",
		is_equal_approx(_hub.power_demand(), 50.0),
		"%.1f units" % _hub.power_demand())


# -------------------------------------------------------------- 8. the clock -----

## The one phase that trusts real frames. The clock node, not the test, must move the
## tank: thirty physics frames of a 60-unit load is half a second, so about 30 units.
func _test_clock() -> void:
	print("-- clock")
	_hub.set_enabled("railgun", false)
	_hub.set_enabled("drill", false)
	_fresh(1000.0, 0.0)
	_hub.set_energy(1000.0)
	_probe("pump", 60.0, 10)
	var changes := _changed
	var start := _hub.energy_charge()
	_hub.clock.set_physics_process(true)
	await _steps(30)
	_hub.clock.set_physics_process(false)
	var spent := start - _hub.energy_charge()
	_ok("the clock spends the reserve while the hull works",
		spent > 20.0 and spent < 40.0, "%.1f units in 30 frames" % spent)
	_ok("the clock raises change events", _changed > changes,
		"%d events" % (_changed - changes))


# --------------------------------------------------------------- 9. the panel ---

func _test_report() -> void:
	print("-- panel")
	var text := "\n".join(_hub.report())
	_ok("the panel prints the reserve and its rate",
		text.contains("reserve") and text.contains("regen"))
	_ok("the panel still prints the bus",
		text.contains("power") and text.contains("consumers"))
	for line in _hub.report():
		print("    " + line)


func _teardown() -> void:
	print("-- teardown")
	for device in _hub.components():
		device.queue_free()
	await _steps(2)
	_ok("every device leaves the bus", _hub.count() == 0,
		"%d left" % _hub.count())
	_hub.set_parameters(_base)
	await _steps(2)
	_ok("the reserve never exceeded its tank",
		_hub.energy_charge() <= _hub.energy_capacity() + 0.001,
		"%.1f / %.1f" % [_hub.energy_charge(), _hub.energy_capacity()])
	_ok("the reserve never went negative", _hub.energy_charge() >= 0.0,
		"%.1f" % _hub.energy_charge())