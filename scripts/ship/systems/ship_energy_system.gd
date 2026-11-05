extends RefCounted
class_name ShipEnergySystem

## The power budget, and the only place the ship decides who gets fed.
##
## One output, many appetites, one rule: sort the consumers by priority, walk them
## highest first, give each what is left until the budget runs out. Whatever a device
## got is written back into it as a 0..1 ratio, and that ratio - not the budget - is
## what turns a brownout into the device's own state. Allocation itself has no
## accumulator: it is a pure function of the registrations, the switches and the
## current output, and it is recomputed only when one of those moves. A hull whose
## power has not changed therefore costs nothing to allocate.
##
## The reserve is the one number that moves on its own. `advance()` is called by
## `ShipEnergyClock` once per physics frame; it spends charge at the granted rate,
## refills it at `energy_recharge_rate`, and re-allocates only when the tank runs
## dry or comes back above the restart line. So the per-frame cost is two multiplications,
## not a walk over the devices.
##
## What this deliberately is not, yet:
##
## - it does not burn fuel, generate heat, or age the reactor - the reserve is a plain
##   tank. `output()` is still the peak the bus may deliver, while `advance()` spends
##   the tank at exactly the rate that was granted and refills it at
##   `energy_recharge_rate`;
## - it does not decide what an appetite means. A sensor's 18 units and a drill's 60
##   are the device's own business; the bus only adds them up;
## - it does not talk to components directly. It reads `draws_power()` and
##   `nominal_power_draw`, and writes `set_power_ratio()`. That is the entire contract,
##   which is why a new device is powered the day it is mounted.
##
## The reserve is stage 4.2's answer at the tank level: `output()` is still the
## instantaneous ceiling, and `advance()` is what pays for delivering it. Fuel, heat and
## reactor wear are still to come, and they will read and write the same group without
## the allocation, the priorities or the events changing.

## The tuning resource. Replaced with the hub's own, never edited per ship clone.
var parameters: ShipSystemsParameters

## The appetites, in the order they are served. Rebuilt on every registration and
## kept sorted so allocation is a single pass - no sort per frame, no ambiguity about
## which of two equal priorities went first.
var _consumers: Array[ShipComponent] = []

## Named auxiliary sources: a solar wing, a battery, a tapped anomaly. A dictionary
## rather than a sum so five sources can be added and removed independently, the same
## rule `ShipController.add_external_acceleration()` follows for pushes.
var _sources := {}

## The reserve moved: the new charge and the capacity it sits in. Emitted by
## `advance()`, `try_spend()`, `add_charge()` and `set_charge()`, never per allocation,
## so a listener reads a level that changed rather than a level that was recomputed.
signal charge_changed(charge: float, capacity: float)
## The charge fell to or below `energy_low_ratio`. Raised once per crossing, not once
## per frame - an alarm, not a level. It never fires at zero; that is `depleted`.
signal low_charge(ratio: float)
## The reserve reached zero and the bus went dark. Devices are already at a grant of
## zero when this arrives, so a listener sees the consequence, not the prediction.
signal depleted
## The reserve climbed back above `energy_restart_ratio` after a depletion and the bus
## is live again.
signal restored

## The live reserve, in power units. Never negative, never above `capacity()`, and
## private because `charge()` is the read side: every write goes through the clamp in
## `_commit()`, so no caller can leave the tank outside its own bounds.
var _stored := 0.0

## Latched: the tank emptied, so `output()` reports nothing until the charge is back
## above the restart line. The latch is the anti-flap rule, and it is why a hull that
## hits zero does not blink back to life on the next unit of regeneration.
var _depleted := false

## Latched: `low_charge` has already been raised for this crossing.
var _low := false

## Is the hull still able to run a plant at all? False after the hull reaches zero
## integrity: the reactor, the auxiliary sources and the devices' own generators then
## deliver nothing, every device is granted nothing, and the tank is frozen. `ShipSystems`
## owns the latch; this flag is only the bus's answer to it.
var _bus_online := true

## Live numbers, for the panel and for a test: what was asked for, what was granted,
## and whether anybody went short.
var _demand := 0.0
var _granted := 0.0
var _starved := false

## The ratio each consumer was granted by the last allocation, keyed by component id.
## Kept because "who is at 0.25?" is the first question a brownout asks, and a
## dictionary answers it without walking the tree.
var last_allocation := {}

## Re-entrancy bookkeeping. Writing a grant back into a device can change its state,
## and the hub answers a state change by asking for another allocation - which is
## correct, because a device that just went offline stops drawing. Without these two
## flags that answer would restart the loop in the middle of itself and add the same
## units to `_granted` twice. With them, the nested call is remembered and replayed
## once the outer pass has finished, which is also the pass that had the full picture.
var _allocating := false
var _allocate_again := false


func _init(params: ShipSystemsParameters = null) -> void:
	parameters = params if params != null else ShipSystemsParameters.new()
	_stored = capacity()


func set_parameters(params: ShipSystemsParameters) -> void:
	parameters = params if params != null else ShipSystemsParameters.new()
	# A retuned hull keeps its charge, but a smaller tank cannot hold it. The latches
	# are re-read here without raising signals: the hub re-allocates right after this
	# call, and a "depleted" line for a capacity the caller just typed would be noise.
	var before := _stored
	_stored = clampf(_stored, 0.0, capacity())
	if not has_reserve():
		_depleted = false
	elif _stored <= 0.0:
		_depleted = true
	elif _stored >= restart_level():
		_depleted = false
	if not is_equal_approx(before, _stored):
		charge_changed.emit(_stored, capacity())


## The total the bus can deliver right now: the reactor plus every auxiliary source plus
## every mounted device that feeds the bus (`ShipComponent.power_supply`), and nothing at
## all while the reserve is empty or the hull is a wreck.
func output() -> float:
	if _depleted or not _bus_online:
		return 0.0
	var total := _finite(settings().reactor_output)
	for id in _sources:
		total += maxf(_finite(float(_sources[id])), 0.0)
	total += device_supply()
	return maxf(total, 0.0)


## What the mounted generators are contributing this allocation, in units. Reads each
## device's own `supplied_power()`, so damage to a power source lowers the budget without
## the energy system holding a second copy of anybody's integrity.
func device_supply() -> float:
	var total := 0.0
	for component in _consumers:
		if component != null and is_instance_valid(component):
			total += maxf(_finite(component.supplied_power()), 0.0)
	return total


## Cut or restore the plant with the hull. While the bus is offline `output()` is zero,
## every device is granted zero in the same call, and `advance()` freezes the tank: a
## wreck neither draws nor regenerates. Restoring it re-allocates, so a device comes back
## under the same rule that starved it.
func set_bus_online(value: bool) -> void:
	if _bus_online == value:
		return
	_bus_online = value
	allocate()


func is_bus_online() -> bool:
	return _bus_online


# ------------------------------------------------------------------- reserve ----

## Full charge, in power units. Zero means the hull has no reserve at all: the bus is
## then unlimited, which is the stage 4.1 behaviour and the deliberate escape hatch.
func capacity() -> float:
	return maxf(_finite(settings().energy_capacity), 0.0)


func has_reserve() -> bool:
	return capacity() > 0.0


## The level as a fraction 0..1. A hull with no reserve reads 1.0 - it is never short.
func charge_ratio() -> float:
	if not has_reserve():
		return 1.0
	return clampf(_stored / capacity(), 0.0, 1.0)


## Charge needed before a depleted bus comes back. Clamped so a restart ratio of 1.0
## cannot ask for more than the tank holds.
func restart_level() -> float:
	return capacity() * clampf(settings().energy_restart_ratio, 0.0, 1.0)


func is_depleted() -> bool:
	return _depleted


func is_low() -> bool:
	return _low


## What the reserve is gaining or losing this second, in units: the regeneration rate
## minus what the last allocation granted. Negative means the hull is living off the
## tank. A panel prints both halves, because "40/s" alone does not say which way.
func net_rate() -> float:
	if not has_reserve() or not _bus_online:
		return 0.0
	return maxf(settings().energy_recharge_rate, 0.0) - maxf(_granted, 0.0)


## The live level, in power units. Read-only on purpose: every write goes through
## `advance()`, `try_spend()`, `add_charge()` or `set_charge()`, which clamp and update
## the latches. A caller that could assign here could leave the tank over capacity.
func charge() -> float:
	return _stored


## One physics step of the tank. The only place charge moves on its own.
##
## Regeneration lands first, then the load is paid for at exactly the units that were
## granted - not at demand, because a device the bus could not feed did not consume
## anything. Running dry latches the bus off; while latched the load is skipped
## entirely (there is nothing left to pay for) and the tank merely refills until it
## clears `energy_restart_ratio`, at which point power is restored in the same step.
##
## A bus cut with the hull (`set_bus_online(false)`) freezes the tank outright: there is
## no reactor to regenerate from and no load to pay, so the reserve is exactly the number
## it had when the ship died until a repair gives the plant a hull to work in.
func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0 or not has_reserve() or not _bus_online:
		return
	var before := _stored
	var next := minf(capacity(),
		_stored + maxf(settings().energy_recharge_rate, 0.0) * delta)
	if not _depleted:
		next = maxf(next - maxf(_granted, 0.0) * delta, 0.0)
	_commit(next, before)


## Can the reserve cover a one-off cost right now? A pure question: it spends nothing,
## so a button may ask it every frame without draining the ship.
func can_afford(amount: float) -> bool:
	if not is_finite(amount):
		return false
	if amount <= 0.0 or not has_reserve():
		return true
	return not _depleted and _stored + 0.0001 >= amount


## Take a one-off cost out of the reserve. The check and the subtraction happen here,
## together, so two callers cannot both pass a separate check and spend the same units.
## Returns false and changes nothing when the reserve is short - which is what makes
## "activation refused" honest rather than a failed activation that was paid for.
func try_spend(amount: float) -> bool:
	if not is_finite(amount):
		return false
	# A cut plant pays for nothing, whatever the tank still holds: the same rule
	# `advance()` follows, so a wreck cannot fund an action around the hub's back.
	if not _bus_online:
		return false
	if amount <= 0.0 or not has_reserve():
		return true
	if not can_afford(amount):
		return false
	var before := _stored
	_commit(maxf(_stored - amount, 0.0), before)
	return true


## Put energy back (a dock, a fuel cell, a scenario grant). Returns what actually fit:
## a tank with 10 units of room accepts 10 of a 500-unit request, not 500.
func add_charge(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or not has_reserve():
		return 0.0
	var before := _stored
	var next := minf(_stored + amount, capacity())
	_commit(next, before)
	return next - before


## Force the level - a save file, a scenario, a test. Clamped to the tank, and the
## latches are re-read so an empty tank cannot be left reporting a live bus.
func set_charge(value: float) -> void:
	if not is_finite(value) or not has_reserve():
		return
	var before := _stored
	_commit(clampf(value, 0.0, capacity()), before)


## Write a new level and answer for everything that follows: clamping, the empty
## latch, the low alarm, the re-allocation that makes a blackout and a recovery true
## of the devices in the same frame, and the signals. Every path that changes charge
## ends here, so the invariants cannot drift apart between callers.
func _commit(next: float, before: float) -> void:
	var was_depleted := _depleted
	var was := before if is_finite(before) else _stored
	_stored = clampf(next if is_finite(next) else was, 0.0, capacity())
	if not has_reserve():
		_stored = 0.0
		_depleted = false
	elif _stored <= 0.0:
		_depleted = true
	elif _stored >= restart_level():
		_depleted = false
	# Between zero and the restart line a depleted tank stays depleted - that is the
	# hysteresis, and it is the whole reason the latch is not just `stored == 0`.
	if _depleted != was_depleted:
		allocate()
		if _depleted:
			depleted.emit()
		else:
			restored.emit()
	_publish_charge(before)


func _publish_charge(before: float) -> void:
	if not is_equal_approx(before, _stored):
		charge_changed.emit(_stored, capacity())
	var ratio := charge_ratio()
	if not _low and ratio > 0.0 and ratio <= settings().energy_low_ratio:
		_low = true
		low_charge.emit(ratio)
	elif _low and ratio > settings().energy_low_ratio:
		_low = false


# ------------------------------------------------------------------ sources ----

## Register a named auxiliary source, in power units. Idempotent per id: registering
## the same id twice replaces its output rather than stacking a second copy.
func add_source(id: String, units: float) -> void:
	_sources[id] = maxf(_finite(units), 0.0)
	allocate()


func remove_source(id: String) -> void:
	if _sources.erase(id):
		allocate()


func clear_sources() -> void:
	_sources.clear()
	allocate()


func source_ids() -> Array:
	return _sources.keys()


# ---------------------------------------------------------------- consumers ----

## Put a device on the bus. Called by the hub, which is the only thing that knows
## every component there is.
func register(component: ShipComponent) -> void:
	if component == null or _consumers.has(component):
		return
	_consumers.append(component)
	_sort_consumers()
	allocate()


func unregister(component: ShipComponent) -> void:
	if component == null:
		return
	var at := _consumers.find(component)
	if at >= 0:
		_consumers.remove_at(at)
	last_allocation.erase(component.resolved_id())
	allocate()


## Share the budget out and write each grant back into its device.
func allocate() -> void:
	if _allocating:
		_allocate_again = true
		return
	_allocating = true
	_allocate()
	_allocating = false
	if _allocate_again:
		_allocate_again = false
		allocate()


func _allocate() -> void:
	_prune()
	var budget := output()
	_demand = 0.0
	_granted = 0.0
	_starved = false
	last_allocation.clear()
	for component in _consumers:
		# A passive device, or one that is switched off or wrecked, is not asking
		# for anything and is granted the whole of its appetite (which is nothing).
		# Writing 1.0 rather than 0.0 keeps "unfed" and "did not ask" apart in the
		# panel, and keeps a device that comes back online from inheriting a stale
		# zero while it waits for the next allocation.
		if not component.draws_power():
			component.set_power_ratio(1.0)
			continue
		var wanted := component.nominal_power_draw
		# An appetite that is not a positive finite number is not an appetite: it is
		# a broken export. Granting it 1.0 is the same answer a passive device gets,
		# and it keeps one NaN out of `_demand`, `_granted` and the ratio written back.
		if not is_finite(wanted) or wanted <= 0.0:
			component.set_power_ratio(1.0)
			continue
		var share := minf(wanted, maxf(budget - _granted, 0.0))
		_demand += wanted
		_granted += share
		var ratio := share / wanted
		last_allocation[component.resolved_id()] = ratio
		if ratio < 0.999:
			_starved = true
		component.set_power_ratio(ratio)


## What the bus was asked for by the devices that are actually drawing, in units.
func demand() -> float:
	return _demand


## What the bus actually gave out, in units.
func granted() -> float:
	return _granted


## Did anybody this allocation go short? A bool, because the *reason* a device suffers
## is the device's own state - this only says the budget was the cause.
func is_starved() -> bool:
	return _starved


## Fraction of the output that is in use, 0..1. A panel reading above 0.9 is a hull
## one device away from a brownout.
func load_ratio() -> float:
	var made := output()
	if made <= 0.0:
		return 0.0
	return clampf(_granted / made, 0.0, 1.0)


func consumer_count() -> int:
	return _consumers.size()


func consumer_ids() -> Array[String]:
	var ids: Array[String] = []
	for component in _consumers:
		if is_instance_valid(component):
			ids.append(component.resolved_id())
	return ids


func settings() -> ShipSystemsParameters:
	if parameters == null:
		parameters = ShipSystemsParameters.new()
	return parameters


## The panel lines: the budget, what is drawing against it, and the devices that are
## going short. Built here so a headless run can read the bus without a renderer.
func report() -> Array[String]:
	var lines: Array[String] = []
	if has_reserve():
		var word := "DEPLETED" if _depleted else ("LOW" if _low else "nominal")
		lines.append("reserve    %5.1f / %5.1f units  %3.0f%%  %s" % [
			_stored, capacity(), charge_ratio() * 100.0, word])
		lines.append("regen      %5.1f /s  net %.1f /s  restart %3.0f%%" % [
			settings().energy_recharge_rate, net_rate(),
			clampf(settings().energy_restart_ratio, 0.0, 1.0) * 100.0])
	else:
		lines.append("reserve    none (unlimited bus)")
	lines.append_array([
		"power      %5.1f / %5.1f units  %s" % [_granted, output(),
			"BROWNOUT" if _starved else ("OFFLINE" if not _bus_online else "nominal")],
		"consumers  %d  load %.0f%%" % [_consumers.size(), load_ratio() * 100.0],
	])
	var supplied := device_supply()
	if supplied > 0.0:
		lines.append("supply     %5.1f units from mounted devices" % supplied)
	var short := ""
	for id in last_allocation:
		if float(last_allocation[id]) < 0.999:
			short += "%s %.0f%%  " % [id, float(last_allocation[id]) * 100.0]
	lines.append("starved    " + (short.strip_edges() if short != "" else "none"))
	return lines


## The one gate for a number that comes from outside: NaN and infinity become zero, so a
## broken export or a scripted hazard cannot poison the budget or the tank. `clampf()`
## keeps a NaN rather than clamping it, which is why the check is here and not there.
static func _finite(value: float) -> float:
	return value if is_finite(value) else 0.0


## Drop devices that have left the tree. The hub unregisters them on `_exit_tree`,
## so this is the belt to that pair of braces - a device freed without a clean exit
## must not keep a slot on the bus for ever.
func _prune() -> void:
	var alive: Array[ShipComponent] = []
	for component in _consumers:
		if component != null and is_instance_valid(component):
			alive.append(component)
	_consumers = alive


## Stable insertion sort, highest priority first. A manual insertion rather than
## `sort_custom()` because Godot's sort is not guaranteed stable, and "the order the
## devices registered" has to be a real rule when two of them share a priority.
func _sort_consumers() -> void:
	var ordered: Array[ShipComponent] = []
	for component in _consumers:
		var at := ordered.size()
		for i in ordered.size():
			if component.power_priority > ordered[i].power_priority:
				at = i
				break
		ordered.insert(at, component)
	_consumers = ordered