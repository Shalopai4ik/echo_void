extends Marker2D
class_name EngineNozzle

## Where one thruster actually is.
##
## A Marker2D with a purpose: the position is the nozzle, `thrust_local` is the
## direction it pushes the hull, and the jet hanging under it is drawn from here.
## Nothing in the code knows a coordinate - move this node in the editor and the
## flame moves with it, which is the whole point of sub-stage 1.2's request that a
## redrawn hull should not require a rewrite.
##
## `thrust_local` is stated as the direction of the *force*, not of the exhaust:
## the plume visibly leaves the opposite way. That is the convention a designer
## reads correctly ("this nozzle pushes the ship to starboard") and it is the one
## the visuals and the diagnostics both need, because the question the plant asks
## is always "which way are we being pushed".

## Which group of the engine plant this nozzle belongs to. The group decides what
## lights it; the anchor itself only says where and which way.
@export_enum("main", "brake", "strafe", "rotation") var thruster := "main"

## The direction this nozzle pushes the hull, in the hull's own axes: +X is the
## nose, +Y is starboard (the screen's down, because a 2D camera looks at the ship
## from above with y growing downward).
@export var thrust_local := Vector2.RIGHT

## For the rotation group only: which way this nozzle yaws the ship when it fires.
## +1 clockwise, -1 counter-clockwise. A yaw vernier is a couple, not a force, so
## it cannot be lit by the direction of a push and has to be told which end of the
## turn it belongs to.
##
## The two couples are mounted on different parts of the airframe rather than at
## the same station facing opposite ways: two plumes that share a stretch of the
## wing edge and run in opposite directions merge into one smear, and a pilot - or
## a pixel check - cannot tell a turn from its reversal.
@export_range(-1, 1) var spin := 0

## How much of its group's power this nozzle is allowed to show. Two nozzles that
## share a station can split it; a decorative spare can be zeroed without deleting
## it.
@export_range(0.0, 1.0, 0.01) var authority := 1.0


## The direction the exhaust leaves in, world space - what the jet has to point at.
func exhaust_world() -> Vector2:
	return (-thrust_local).rotated(global_rotation)


## The direction this nozzle pushes, world space.
func thrust_world() -> Vector2:
	return thrust_local.rotated(global_rotation)


## How well this nozzle can serve a push along `wanted_local` (unit, in the hull's
## own axes): 1.0 when it is aimed exactly at it, 0 when it is sideways or behind.
## The brake and strafe groups are lit through this, which is what makes a retro
## burn show up on the side of the ship the speed is actually coming from instead
## of always on the nose.
##
## Stated in hull axes on purpose, because that is the frame the plant reports its
## push in. Comparing a hull-local direction against this nozzle's *world* thrust
## would only agree while the ship happens to point along +X - and a retro burn
## while flying east with the nose up would then light the starboard verniers.
func alignment_local(wanted_local: Vector2) -> float:
	if wanted_local.length_squared() < 0.0001:
		return 0.0
	return maxf(0.0, thrust_local.dot(wanted_local))
