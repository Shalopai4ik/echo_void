extends RefCounted
class_name ShipHealthSystem

## What is left of the ship, and of every device on it.
##
## This is the only writer of integrity anywhere in the hull. Components hold the
## number (they are the things that exist and can be looked at), the hub calls into
## this class to change it, and no device, HUD or event handler gets to set its own
## condition. That single writer is the whole reason the three states can be trusted:
## if a sensor reads DAMAGED, something here wrote a number below the line, and the
## line is in `ShipSystemsParameters` where a designer can see it.
##
## Two ledgers, deliberately apart:
##
## - **the hull**, one number in hit points between 0 and `hull_max_integrity`, which is
##   the ship's own skin. It has no component id and no switch, so it cannot be "off" -
##   only whole or wrecked. The default maximum is 1.0, so the number is also the ratio
##   the layer started with; `hull_ratio()` is always the fraction the state rules and a
##   HUD consume, whatever the maximum is.
## - **the components**, each holding its own ratio. There is no copy of them here;
##   a second copy is a copy that can disagree.
##
## Everything a device carries is still a ratio, not hit points. The hull is the one
## place a designer may ask for a real pool, because a hull's worth is a game number and
## a sensor's is not. Damage that is negative, zero, NaN or infinite is refused here -
## this is the last gate before the number is written, so a bad caller cannot leave the
## hull at `NaN` and quietly disable every comparison downstream.

## The tuning resource, shared with the rest of the layer.
var parameters: ShipSystemsParameters

## The hull's own integrity, in hit points. Starts at `hull_max_integrity`, never below
## zero, never above the maximum.
var hull_integrity := 1.0


func _init(params: ShipSystemsParameters = null) -> void:
	parameters = params if params != null else ShipSystemsParameters.new()
	hull_integrity = hull_max()


## A retune keeps the hull's condition: the fraction survives a change of maximum, so a
## designer raising `hull_max_integrity` from 1 to 100 does not heal or kill the ship.
func set_parameters(params: ShipSystemsParameters) -> void:
	var ratio := hull_ratio()
	parameters = params if params != null else ShipSystemsParameters.new()
	hull_integrity = ratio * hull_max()


# ---------------------------------------------------------------- components --

## Take `amount` of integrity off a device and return how much was actually taken.
## Clamped to what is left, so a 0.9 hit on a 0.2 device reports 0.2 - a caller that
## sums the returns gets the truth about the damage it caused, not the damage it
## asked for.
func damage(component: ShipComponent, amount: float) -> float:
	var value := _finite_positive(amount)
	if component == null or not is_instance_valid(component) or value <= 0.0:
		return 0.0
	var applied := minf(value, component.integrity)
	component.set_integrity(component.integrity - applied)
	return applied


## Put integrity back, up to whole. Repairs never overflow into a bonus.
func repair(component: ShipComponent, amount: float) -> float:
	var value := _finite_positive(amount)
	if component == null or not is_instance_valid(component) or value <= 0.0:
		return 0.0
	var applied := minf(value, 1.0 - component.integrity)
	component.set_integrity(component.integrity + applied)
	return applied


# ---------------------------------------------------------------------- hull --

## What a whole hull is worth. Read through the tuning resource every time, so a retune
## is one assignment rather than a second copy of the number here.
func hull_max() -> float:
	return maxf(settings().hull_max_integrity, 0.0001)


## The hull takes the hit. Clamped to what is left, in the hull's own points, and the
## returned value is what was actually applied - a caller that sums returns gets the
## truth, not the request.
func damage_hull(amount: float) -> float:
	var value := _finite_positive(amount)
	if value <= 0.0:
		return 0.0
	var applied := minf(value, hull_integrity)
	hull_integrity = maxf(hull_integrity - applied, 0.0)
	return applied


func repair_hull(amount: float) -> float:
	var value := _finite_positive(amount)
	if value <= 0.0:
		return 0.0
	var applied := minf(value, maxf(hull_max() - hull_integrity, 0.0))
	hull_integrity = minf(hull_integrity + applied, hull_max())
	return applied


## The fraction of the hull that is left, whatever the maximum is. This is the number
## the three states and a HUD read; `hull_integrity` is the pool behind it.
func hull_ratio() -> float:
	return clampf(hull_integrity / hull_max(), 0.0, 1.0)


## The hull's condition, in the same three words the devices use. A hull cannot be
## switched off, so the switch argument is always true; it is still the shared rule,
## not a second one written out here.
func hull_state() -> int:
	return ShipSystemState.evaluate(true, hull_ratio(), 1.0, settings())


## The hull is out of integrity. Not "the ship is deleted" - that is the destruction
## stage's call - just that there is nothing left of the skin.
func hull_is_lost() -> bool:
	return hull_integrity <= 0.0


## Mean integrity across the devices that are actually mounted, or the hull's own
## ratio when there are none. A hull with no equipment reports the hull, which is the
## only honest answer to "how is the ship" before the first sensor is installed.
func average_ratio(components: Array[ShipComponent]) -> float:
	if components.is_empty():
		return hull_ratio()
	var total := 0.0
	for component in components:
		if component != null and is_instance_valid(component):
			total += component.integrity
	return total / float(components.size())


## The one gate every amount of damage and repair passes through. Negative, zero, NaN
## and infinite values all become 0.0, so no caller can write a number the clamps below
## would then compare against forever.
static func _finite_positive(value: float) -> float:
	if not is_finite(value) or value <= 0.0:
		return 0.0
	return value


func settings() -> ShipSystemsParameters:
	if parameters == null:
		parameters = ShipSystemsParameters.new()
	return parameters


## The panel lines. One line per ledger, because the two answer different questions
## and a reader that only sees an average cannot tell a scratched hull from a hull
## whose sensors are all dead.
func report() -> Array[String]:
	return [
		"hull       %6.1f / %-6.1f %3d%%  %s" % [hull_integrity, hull_max(),
			int(roundf(hull_ratio() * 100.0)), ShipSystemState.name_of(hull_state())],
	]