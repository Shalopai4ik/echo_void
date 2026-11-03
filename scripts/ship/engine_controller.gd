extends Node
class_name EngineController

## The engine plant's single answer to "what are the thrusters doing right now".
##
## Sub-stage 1.2 asked for a system that other parts of the game can interrogate
## instead of guess at: is the main engine lit, are the manoeuvring jets firing,
## how hard is each group working, which way is the plant pushing, how loaded is
## the whole arrangement. Every one of those questions is answered here, from one
## place, and nowhere else computes them.
##
## What this deliberately is not: a source of force. The flight model in
## `ship_controller.gd` integrates the hull and owns every acceleration number
## (spec 4: if the physics already computes the acceleration from W, the engine
## system must hand it state and power, not add a second acceleration). So the
## ship asks for a burn, this file turns that request into a power between 0 and 1
## over the group's response time, and the ship multiplies its own acceleration by
## what comes back. One multiplication, one application, and a test can prove it.
##
## The four groups are the four the ship is built from:
## - MAIN burns along the nose on W.
## - BRAKE burns against the velocity vector on S while the hull still has speed.
## - ASTERN burns out of the tail on S once the speed is gone.
## - STRAFE burns across the hull on Q and E, and turns nothing.
## - ROTATION works the yaw verniers on A and D.
## BRAKE and ASTERN are the same lever read two ways, which is exactly the split
## 1.1 made in `_apply_retro`: braking first, then reverse, never both at once and
## never a fight between them.
##
## Sub-stage 1.3 added three more hands on those same five levers - the pilot's
## keys, the stabilizer, the emergency brake and the boost - and the plant is
## unchanged in the one respect that matters: it is still handed a request and
## returns a power. Whose hand it is comes in on the `FlightOrder` as a scale, and
## the scales are ceilings, never extra force. That is why a borrowed retro burn from
## the stabilizer draws the same four nozzles as the pilot's S, only fewer of them
## and dimmer, and why boost lengthens the main plume instead of needing its own
## effect.

## Which group a reader is asking about, and the order `report()` prints them in.
enum Group { MAIN, BRAKE, ASTERN, STRAFE, ROTATION }

## The braking lever, as the flight model decided it for this frame. Passed in
## rather than read here, because the decision needs the hull's real velocity and
## belongs to the physics.
enum Retard { NONE, BRAKING, ASTERN }

## The tuning surface. Left unset, the ship's own parameters are used; a resource
## assigned here overrides it, which is how a later stage re-tunes one hull.
@export var parameters: ShipEngineParameters

## Live power of each group, 0..1 (signed for the two groups that come in pairs:
## STRAFE is -1 port .. +1 starboard, ROTATION is -1 counter-clockwise .. +1
## clockwise). These are what the visuals read and what the diagnostics print.
var main_power := 0.0
var brake_power := 0.0
var astern_power := 0.0
var strafe_power := 0.0
var rotation_power := 0.0

## Which way the plant is pushing this frame, in the hull's own axes: x along the
## nose, y to starboard. Rotation is a couple, not a force, so it is not in here -
## a reader that wants the yaw demand asks for `rotation_power`.
var thrust_local := Vector2.ZERO

## The direction the retro burn is pointing this frame, in hull axes: the flight
## model derived it from the velocity vector, and the visuals need it separately,
## because "the ship is being pushed aft" and "the brakes are burning" are two
## different statements about the same arrow.
var brake_dir_local := Vector2.ZERO

## The same push in world space. The hull axes are what the physics and the nozzle
## blending work in; this is what a reader outside the ship - a diagnostic, a HUD,
## a targeting stage - wants, and deriving it here keeps "whose frame is this?"
## from becoming a per-caller guess.
var brake_direction_world := Vector2.ZERO

# The request the flight model made on the last frame, kept so the ramps know what
# they are ramping toward between calls.
var _demand_main := 0.0
var _demand_brake := 0.0
var _demand_astern := 0.0
var _demand_strafe := 0.0
var _demand_rotation := 0.0


## The one entry point. Called by the ship once per physics frame, before it applies
## any burn, so every group's power is this frame's number rather than last frame's.
##
## Since 1.3 the request arrives as a `FlightOrder` instead of five loose arguments,
## because there are now four callers of those five things: the pilot's keys, the
## stabilizer, the emergency brake and the boost. The order carries who is asking,
## and each `*_scale` is the answer to "how much of this group may that hand use" -
## 1.0 for the pilot's own levers, a fraction for a borrowed one, and above 1.0 only
## for the main group under boost. Nothing else in the ship may raise a ceiling, and
## no group's scale is a force: the flight model still multiplies its own
## accelerations by whatever comes back out of here.
func step(order: FlightOrder, delta: float) -> void:
	var p := settings()
	_demand_main = 1.0 if order.main_thrust else 0.0
	_demand_brake = 1.0 if order.retard == Retard.BRAKING else 0.0
	brake_dir_local = order.brake_direction if order.retard == Retard.BRAKING else Vector2.ZERO
	brake_direction_world = brake_dir_local.rotated(_hull_rotation())
	_demand_astern = 1.0 if order.retard == Retard.ASTERN else 0.0
	_demand_strafe = clampf(order.strafe_axis, -1.0, 1.0)
	_demand_rotation = clampf(order.rudder_axis, -1.0, 1.0)

	# Boost is the only thing allowed to ask for more than a group's ceiling, and it
	# asks by multiplying that ceiling rather than by adding a force somewhere.
	main_power = _ramp(main_power, _demand_main * p.main_engine_max_power * order.main_scale,
		p.main_engine_response_time, p.main_engine_shutdown_time, delta)
	# The emergency brake needs a faster bite than the ordinary retro burn without
	# changing what the pilot's S does, so its rise time rides on the order.
	var brake_rise := order.brake_rise if order.brake_rise > 0.0 else p.braking_engine_response_time
	brake_power = _ramp(brake_power, _demand_brake * p.braking_engine_max_power * order.brake_scale,
		brake_rise, p.braking_engine_response_time, delta)
	# Astern shares the braking lever's bite: it is the same nozzles asked for the
	# other half of the envelope, and it has to be gone the moment S comes off.
	astern_power = _ramp(astern_power, _demand_astern * p.braking_engine_max_power,
		p.braking_engine_response_time, p.braking_engine_response_time, delta)
	strafe_power = _ramp(strafe_power, _demand_strafe * order.strafe_scale,
		p.maneuvering_engine_response_time, p.maneuvering_engine_response_time, delta)
	rotation_power = _ramp(rotation_power, _demand_rotation * p.rotation_engine_power * order.rotation_scale,
		p.rotation_engine_response_time, p.rotation_engine_response_time, delta)

	thrust_local = Vector2.RIGHT * main_power \
		+ Vector2.LEFT * astern_power \
		+ order.brake_direction * brake_power \
		+ Vector2.DOWN * strafe_power


## The resource the plant actually runs on: the one assigned here, or the one the
## ship carries, or a default instance so nothing in the system has to be written
## with null checks.
func settings() -> ShipEngineParameters:
	if parameters != null:
		return parameters
	var owner := get_parent()
	if owner != null and owner.get("parameters") is ShipEngineParameters:
		return owner.parameters
	return ShipEngineParameters.new()


## Power of one group, for a reader that only knows the enum.
func power(group: Group) -> float:
	match group:
		Group.MAIN:
			return main_power
		Group.BRAKE:
			return brake_power
		Group.ASTERN:
			return astern_power
		Group.STRAFE:
			return absf(strafe_power)
		Group.ROTATION:
			return absf(rotation_power)
	return 0.0


## Is this group burning enough to be worth drawing or reporting. The floor is a
## power's floor, not an input's: a group that is still fading out reads active
## until it is genuinely dark, which is what keeps the jets and the numbers
## agreeing with each other.
func is_active(group: Group) -> bool:
	return power(group) > 0.02


## Signed demand of the strafe pair: -1 full port, +1 full starboard.
func brake_direction_local() -> Vector2:
	return brake_dir_local


func strafe_demand() -> float:
	return strafe_power


## Signed demand of the yaw verniers: -1 counter-clockwise, +1 clockwise.
func rotation_demand() -> float:
	return rotation_power


## The unit vector the linear groups are pushing along, in hull axes, or zero when
## nothing is burning. This is the direction the brake nozzles have to face and the
## direction the diagnostics print.
func thrust_direction_local() -> Vector2:
	return thrust_local.normalized()


## The same in world space, for anything that draws or measures outside the hull.
func thrust_direction() -> Vector2:
	return thrust_direction_local().rotated(_hull_rotation())


## How hard the whole plant is working: the sum of the groups' power, so 1.0 is one
## group at full and about 3.0 is the ship braking, strafing and turning at once.
## Deliberately un-normalised - a HUD that wants a percentage has to decide which
## groups it counts as load, and that is a design call, not a physics one.
func total_load() -> float:
	return main_power + brake_power + astern_power + absf(strafe_power) \
		+ absf(rotation_power)


## The lines the diagnostics print. Built here rather than in the overlay so a
## headless run can read the plant's state without a renderer.
func report() -> Array[String]:
	return [
		"main      %s" % _bar(main_power),
		"brake     %s" % _bar(brake_power),
		"astern    %s" % _bar(astern_power),
		"strafe    %s" % _bar(strafe_power),
		"spin      %s" % _bar(rotation_power),
		_thrust_line(),
		"load      %.2f" % total_load(),
	]


func _hull_rotation() -> float:
	var owner := get_parent()
	if owner is Node2D:
		return (owner as Node2D).rotation
	return 0.0


## A linear ramp toward the demand: up over `rise` seconds, down over `fall`.
## Linear rather than exponential because the spec asks for a *time to full power*,
## and a number you can hold a stopwatch to is worth more than a curve that only
## ever approaches its target.
##
## The clamp is `max(1.0, |target|)`, not a flat 1.0: every group but one is an
## authority between 0 and 1, and the exception is the main engine under boost,
## which is allowed to be handed a multiple of its ceiling. Leaving the flat clamp in
## place would have made boost silently do nothing at exactly the moment it was
## supposed to bite.
func _ramp(current: float, target: float, rise: float, fall: float, delta: float) -> float:
	var rate := 1.0 / maxf(rise if absf(target) > absf(current) else fall, 0.001)
	var bound := maxf(1.0, absf(target))
	return clampf(move_toward(current, target, rate * delta), -bound, bound)


func _bar(value: float) -> String:
	return "%6.2f %s" % [value, "on" if absf(value) > 0.02 else "-"]


## The push line, or the honest "none" when nothing is burning: an angle of a zero
## vector is a number that means nothing and would be read as a heading.
func _thrust_line() -> String:
	if thrust_local.length() < 0.01:
		return "thrust    none"
	# The angle and the unit direction, not a magnitude: `thrust_local` is a sum of
	# powers, and the px/s^2 a reader wants is on the ship's own panel.
	return "thrust    %s deg (%s, %s)" % [
		_num(rad_to_deg(thrust_direction_local().angle())),
		_num(thrust_direction_local().x), _num(thrust_direction_local().y)]


## A number with the negative zero folded away, same reason as the flight panel.
func _num(value: float) -> String:
	var text := "%.2f" % value
	if text == "-0.00":
		return "0.00"
	return text
