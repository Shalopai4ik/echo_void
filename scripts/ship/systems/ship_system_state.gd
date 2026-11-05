extends RefCounted
class_name ShipSystemState

## The one place that decides what "working" means for a component of the ship.
##
## Three words, because the brief asks for three: NOMINAL, DAMAGED, OFFLINE. They
## are not three switches and they are not three flags - they are what falls out of
## two facts a component already knows about itself (is the crew switch on, how much
## of it is left) and one it is told (how much power it was actually granted).
##
## Keeping that rule here, as one pure function, is what stops a component, the
## energy system and the HUD from each inventing their own opinion about when a
## device counts as broken. It is also why the state is never *set* anywhere: a
## device does not "become damaged" because somebody said so, it becomes damaged
## because its integrity crossed a line, and this file is the line.
##
## The checks are applied in the order of the answer:
##   0. the hull is a wreck                                      -> OFFLINE (no ship)
##   1. the crew switch is off                                  -> OFFLINE
##   2. integrity at or below `offline_integrity`                -> OFFLINE (wrecked)
##   3. power grant at or below `offline_power_ratio`            -> OFFLINE (starved)
##   4. integrity below `damaged_integrity`, or the grant below
##      `damaged_power_ratio`                                   -> DAMAGED
##   5. otherwise                                                -> NOMINAL
##
## Rule 0 is the hull's own condition, not the device's: nothing on a wreck is doing
## its job, whatever its switch and its integrity say. It is an argument rather than a
## fourth stored field because the hull's latch belongs to `ShipSystems`; a component
## asks the hub, the pure function only answers.
##
## A device with no power demand is granted 1.0 by the energy system, so the third
## and fourth checks simply never fire for it - a passive antenna does not read as
## starved because it was not allocated anything.

## The three conditions, in increasing severity. The order is part of the contract:
## `worst()` and the aggregate ship state depend on it, and so does the debug panel.
enum Value { NOMINAL, DAMAGED, OFFLINE }

## Cached default so `evaluate()` never allocates a resource on a hot path. The
## project's rule is that a system without a tuning resource still works, and this
## is that rule with a single instance behind it instead of one per call.
static var _fallback: ShipSystemsParameters


## The state of a device, from the three numbers that decide it, and the one fact about
## the ship it cannot see for itself. `hull_alive` defaults to true so a device built or
## evaluated outside a ship keeps the rule it always had.
static func evaluate(enabled: bool, integrity: float, power_ratio: float,
		parameters: ShipSystemsParameters, hull_alive := true) -> int:
	var p := of(parameters)
	if not hull_alive:
		return Value.OFFLINE
	if not enabled:
		return Value.OFFLINE
	if integrity <= p.offline_integrity:
		return Value.OFFLINE
	if power_ratio <= p.offline_power_ratio:
		return Value.OFFLINE
	if integrity < p.damaged_integrity or power_ratio < p.damaged_power_ratio:
		return Value.DAMAGED
	return Value.NOMINAL


## The word a log or a panel prints.
static func name_of(value: int) -> String:
	var names := Value.keys()
	if value < 0 or value >= names.size():
		return "UNKNOWN"
	return String(names[value])


## Is the device doing its job at all? `DAMAGED` counts: it works, reduced, and a
## caller that wants "full or nothing" asks `== Value.NOMINAL` instead.
static func is_operational(value: int) -> bool:
	return value != Value.OFFLINE


## How bad this state is, for `worst()` and for sorting a panel. OFFLINE is the
## worst thing a single device can be, so it sorts last - not first - in the list
## a reader scans.
static func rank_of(value: int) -> int:
	match value:
		Value.OFFLINE:
			return 2
		Value.DAMAGED:
			return 1
		_:
			return 0


## The worse of two states, so a hull can answer "how is the ship" with one word
## without the caller having to fold a list itself.
static func worst(a: int, b: int) -> int:
	return a if rank_of(a) >= rank_of(b) else b


## The tuning resource, or the shipping defaults when a component was built in code
## without one. Shared, because the defaults are the shipping numbers, not a
## per-instance fallback.
static func of(parameters: ShipSystemsParameters) -> ShipSystemsParameters:
	if parameters != null:
		return parameters
	if _fallback == null:
		_fallback = ShipSystemsParameters.new()
	return _fallback