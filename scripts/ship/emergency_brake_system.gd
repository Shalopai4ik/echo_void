extends RefCounted
class_name EmergencyBrakeSystem

## The one lever allowed to outrank the pilot's own throttle.
##
## S is a controlled burn: `braking_acceleration` over the retro plant's response
## time, and it is the pilot's decision from beginning to end. Space is what the
## pilot asks when the decision has been made for them by a rock: the same two
## groups, pointed the same way - strictly against the velocity the hull actually
## has - at the hardest deceleration the plant is configured for, and it bites faster
## than S does.
##
## Three things this does not do, and each is a rule the spec states:
## - It does not zero the velocity. There is no `linear_velocity = Vector2.ZERO`
##   anywhere in the ship, and this file could not write one if it wanted to: the
##   answer here is a *deceleration* and a direction, and the flight model spends it
##   over `delta` exactly like any other burn. The burn stays capped at the speed
##   that is left, so the hull is slowed, never flipped.
## - It does not aim at the nose. The direction comes from the velocity vector in the
##   hull's own axes, so a ship flying east with its nose up brakes westward and
##   never starts backing up along its tail.
## - It does not keep firing at rest. Below `emergency_brake_stop_threshold` the
##   system lets go completely: no authority, no flame, no chattering at a hull that
##   has already stopped. That threshold sits above the ship's own
##   `velocity_stop_threshold`, so the rest snap - not the thrusters - finishes the
##   last px/s, which is what "no jitter around zero" actually means here.
##
## What it gives up for being the strongest thing on the lever: while it is engaged,
## the main engine is off. Not because W is ignored harshly, but because a ship being
## hauled out of its speed and thrown back into it at the same time would have both
## groups burn and neither reach its target - and the pilot reading the panel would
## see two answers to one question. A/D and Q/E keep working throughout, because
## pointing the hull and sliding sideways do not fight a retro burn: they change
## where the ship will go *after* it stops, which is exactly what someone dodging
## something needs.

## Whether the key is held. Written by the flight model from the input map.
var held := false

## Whether the system is braking this frame - held, and with enough speed left to be
## worth burning for. This is the flag the panel prints and the tests read.
var engaged := false

## The deceleration on offer, px/s^2, straight from the parameters. The flight model
## multiplies it by the retro group's ramped power, so this is a ceiling on the
## frame's burn, not the burn itself.
var deceleration := 0.0

## Why the lever is not biting right now, for the panel: `held` / `no-speed` / `off`.
var reason := "off"

var parameters: ShipAssistParameters


func _init(params: ShipAssistParameters = null) -> void:
	parameters = params if params != null else ShipAssistParameters.new()


## One frame of deciding. `ship_frame` is the velocity in the hull's own axes and
## `lever` is the key as the flight model read it, so a hull with
## `movement_enabled = false` cannot be emergency-braked by a key that is still
## physically down. The system only looks at the vector's length, because the
## direction it needs is the one the flight model already derived.
func step(ship_frame: Vector2, lever: bool) -> void:
	var p := settings()
	held = lever
	var speed := ship_frame.length()
	reason = "off"
	if held:
		if speed <= p.emergency_brake_stop_threshold:
			# Nothing to brake, and no reason to light four retro nozzles to argue
			# with a rest threshold that is already doing the job.
			reason = "no-speed"
			engaged = false
		else:
			engaged = true
			reason = "held"
	else:
		engaged = false
	# The authority falls away with the lever; the ramp is the plant's own, so the
	# flame goes out over the brakes' shutdown, not in one frame.
	deceleration = p.emergency_brake_max_deceleration if engaged else 0.0


## The lines the diagnostics print.
func report() -> Array[String]:
	var p := settings()
	return [
		"e-brake    %s (%s)" % ["ON" if engaged else "OFF", reason],
		"e-brake    %.0f px/s^2  stop < %.1f  bite %.2fs" % [
			p.emergency_brake_max_deceleration, p.emergency_brake_stop_threshold,
			p.emergency_brake_response_time],
	]


func settings() -> ShipAssistParameters:
	if parameters == null:
		parameters = ShipAssistParameters.new()
	return parameters
