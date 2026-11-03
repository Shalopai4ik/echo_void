extends RefCounted
class_name FlightOrder

## Whose lever is whose, for one physics frame.
##
## Sub-stage 1.3 put three more callers in front of the same four groups of
## thrusters: the pilot, the stabilizer, the emergency brake and the boost. The
## failure mode the spec warns about twice - several systems each editing the hull's
## speed on their own - is prevented by making every one of them *fill this in*
## instead of touching the body, and by having exactly one reader: the flight model
## resolves the ownership, the plant turns it into powers, and the hull is integrated
## once.
##
## So this is not a command queue and not a force accumulator. It is the answer to
## "who is asking for what, and how hard", written by the resolver and read by the
## plant. `owner_*` says who got the lever, which is the part a pilot's complaint
## ("something is flying my ship") is actually about, and what the debug panel prints.

## W reached the engine at all. Space takes this away: a ship being hauled to a stop
## by its retro plant must not simultaneously be thrown forward by the main one.
var main_thrust := false

## What the main engine's authority may be multiplied by - the whole of what boost
## contributes to the physics. 1.0 when nothing is boosting.
var main_scale := 1.0

## The forward-speed ceiling in force this frame, world px/s. Boost lifts it; the
## ceiling still only caps the thrusters, never a faster speed the hull already has.
var forward_ceiling := 0.0

## Which half of the retro lever, decided from the real velocity by the flight model:
## `EngineController.Retard.NONE`, `BRAKING` or `ASTERN`.
var retard := 0

## The direction the retro burn pushes, unit, in the hull's own axes. Whatever is
## holding the lever - pilot, stabilizer or the emergency brake - the answer is
## always "against the velocity the hull actually has", never "along the tail".
var brake_direction := Vector2.ZERO

## Authority the retro group is allowed to reach, 0..1. The stabilizer's fraction of
## the plant's is what makes its burn weaker than a pilot's S.
var brake_scale := 1.0

## Seconds for the retro group to reach that authority; 0 or less means the group's
## own `braking_engine_response_time`. The emergency brake uses it to bite harder
## than ordinary braking without changing what the pilot's S does.
var brake_rise := 0.0

## The deceleration the retro owner is working with, px/s^2: `braking_acceleration`
## for the pilot and the stabilizer, `emergency_brake_max_deceleration` for Space.
## Multiplying it by `brake_scale` never double-counts: the scale is the *ramped*
## authority, this is the ceiling that authority is a fraction of.
var retro_deceleration := 0.0

## Q and E, -1 port .. +1 starboard. Filled by the pilot's keys, or by the
## stabilizer's sideways correction when the pilot is not holding either.
var strafe_axis := 0.0

## Authority of whichever lever owns the sideways group, 0..1.
var strafe_scale := 1.0

## A/D, -1 counter-clockwise .. +1 clockwise, or the stabilizer's spin correction.
var rudder_axis := 0.0

## Authority of whichever lever owns the yaw verniers, 0..1.
var rotation_scale := 1.0

## Who is flying each job this frame, for the panel: `pilot`, `stabilizer`,
## `emergency`, `boost`, `-`. A conflict between two systems is only findable if the
## frame says which one won.
var owner_main := "-"
var owner_retro := "-"
var owner_strafe := "-"
var owner_rudder := "-"


## Everything back to "nobody is asking". Called once per frame before the resolver
## writes it, so a stale `true` from last frame cannot survive into this one.
func reset() -> void:
	main_thrust = false
	main_scale = 1.0
	forward_ceiling = 0.0
	retard = 0
	brake_direction = Vector2.ZERO
	brake_scale = 1.0
	brake_rise = 0.0
	retro_deceleration = 0.0
	strafe_axis = 0.0
	strafe_scale = 1.0
	rudder_axis = 0.0
	rotation_scale = 1.0
	owner_main = "-"
	owner_retro = "-"
	owner_strafe = "-"
	owner_rudder = "-"
