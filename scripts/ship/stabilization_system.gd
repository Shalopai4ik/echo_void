extends RefCounted
class_name StabilizationSystem

## Borrowed thrusters, not a new set of physics.
##
## What the stabilizer is allowed to do is exactly one thing: notice the speed the
## hull has that the pilot is not asking for, and press the levers that are already
## in the ship for it. The retro plant kills the component along the nose, the
## manoeuvring pair kills the component across it, the yaw verniers kill the spin.
## Those are 1.2's groups with 1.2's response times, so the jets on screen are the
## jets doing the work, and the flight model stays the only writer of velocity.
##
## What it pointedly does not do:
## - It does not re-aim the ship. There is no heading in this file, no target angle
##   and no torque that would walk the nose somewhere. A hull spinning free after A
##   is let go loses its rotation and keeps whatever direction it ends up facing -
##   the difference between a stabilizer and an autopilot, and what the spec's test 7
##   of the stabilization section checks.
## - It does not outrank the pilot. Every axis is split by lever: while W is held the
##   along-axis is the pilot's and the assist stays off it; while E is held the
##   sideways job is the pilot's; while A or D is held the turn is the pilot's. The
##   authority it may borrow is also capped below the pilot's own numbers
##   (`stabilization_max_linear_correction` < `braking_acceleration`,
##   `stabilization_max_lateral_correction` < `maneuvering_engine_power`), so even on
##   an untouched lever the assist is the weaker hand.
## - It does not chase nothing. Below `stabilization_dead_zone` there is no demand at
##   all, so a hull that is practically parked cannot leave a vernier ticking over
##   forever, and the ship's own rest threshold finishes the last few px/s.
##
## The correction is split into the hull's own axes rather than taken as one vector
## against the velocity, and that is what stops the two linear groups from burning
## the same px/s twice: the retro plant owns x, the manoeuvring pair owns y. A
## broadside drift therefore lights the strafe jets and nothing else, which is also
## what a pilot watching the ship would expect to see.

## The hull these numbers belong to. The assist reads the *live* exported
## accelerations and thresholds through it, so re-tuning an engine in the inspector
## moves the stabilizer's borrow with it instead of leaving a private copy that lies.
var ship: ShipController

## Whether the system is switched on. Toggled by the player, seeded from
## `stabilization_enabled_by_default`, and the only state a save would want.
var enabled := false

## How much of its borrowed authority has actually come up: 0..1 over
## `stabilization_response_time`. This is what makes switching it on mid-glide a
## leaning rather than a lurch, and what the panel prints as the system's own power.
var authority := 0.0

# The three requests as signed lever positions, -1..1, filled in by `step()` and read
# by the resolver. The direction is the whole answer: `along = -1` means "burn so as
# to take the nose-ward speed back", and the retro nozzles turn to match.
var along := 0.0
var lateral := 0.0
var spin := 0.0

# The authority ceilings the assist may use on each group, ramped by `authority` and
# capped by the px/s^2 limits. These go into the order as the groups' scales, which
# is why the plant's power - and so the picture - is the assist's real strength.
var retro_scale := 0.0
var strafe_scale := 0.0
var rotation_scale := 0.0

## The speed the assist can see and is not yet done with, px/s: the larger of the two
## components it is actually working on. The panel's "residual drift" line.
var residual := 0.0

var parameters: ShipAssistParameters


func _init(params: ShipAssistParameters = null) -> void:
	parameters = params if params != null else ShipAssistParameters.new()
	enabled = parameters.stabilization_enabled_by_default


## One frame of looking. `ship_frame` is the hull's velocity in its own axes (x along
## the nose, y to starboard), `angular_rate` is the yaw, and the four `pilot_*` flags
## say which levers a hand is already on. Called by the flight model before the order
## is resolved; it never returns a velocity or a force.
func step(ship_frame: Vector2, angular_rate: float, pilot_main: bool, pilot_retro: bool,
		pilot_strafe: bool, pilot_rudder: bool, delta: float) -> void:
	var p := settings()
	if ship == null:
		# No hull to read, so nothing to borrow. Every number the assist needs comes
		# from the ship's own exports; there are no fallback constants here, because a
		# made-up 760 px/s^2 is exactly the kind of number that goes quietly wrong when
		# the hull's real one is retuned.
		return
	var wanted := 1.0 if enabled else 0.0
	authority = move_toward(authority, wanted, delta / maxf(p.stabilization_response_time, 0.001))
	if authority >= 0.999:
		authority = 1.0

	# Every request starts from nothing, including while the assist is still coming
	# up or on its way out: a cold stabilizer asks the plant for zero power, so it
	# draws no flame, and the visual layer never has to know the system exists.
	along = 0.0
	lateral = 0.0
	spin = 0.0
	retro_scale = 0.0
	strafe_scale = 0.0
	rotation_scale = 0.0
	residual = 0.0
	if not enabled or authority <= 0.0:
		return

	# Along the nose. W is a deliberate speed and S a deliberate brake, so the axis is
	# the pilot's in both directions and nothing here is left to correct.
	if not pilot_main and not pilot_retro and absf(ship_frame.x) > p.stabilization_dead_zone:
		along = -signf(ship_frame.x)
		retro_scale = authority * _borrow(p.stabilization_linear_power,
			p.stabilization_max_linear_correction, _retro_group())

	# Across it. Q and E own this axis; W and S do not, so a deliberate forward burn
	# while sliding sideways still gets the slide taken out - the spec's own example
	# of a nose-up hull flying east, corrected without touching the nose.
	if not pilot_strafe and absf(ship_frame.y) > p.stabilization_dead_zone:
		lateral = -signf(ship_frame.y)
		strafe_scale = authority * _borrow(p.stabilization_linear_power,
			p.stabilization_max_lateral_correction, _maneuvering_group())

	# Yaw. While the rudder is held it is the pilot's; after release the hull's own
	# `angular_deceleration` is already working on the rate, and the verniers add to
	# it - so only what is left of the ceiling may be borrowed, which is what keeps
	# the spin-down gradual instead of instantaneous.
	if not pilot_rudder and absf(angular_rate) > _angular_stop():
		spin = -signf(angular_rate)
		rotation_scale = authority * _borrow_turn(p.stabilization_angular_power,
			p.stabilization_max_angular_correction)

	var along_left := absf(ship_frame.x) if along != 0.0 else 0.0
	var across_left := absf(ship_frame.y) if lateral != 0.0 else 0.0
	residual = maxf(along_left, across_left)


## Flip, as the key does.
func toggle() -> void:
	set_enabled(not enabled)


func set_enabled(value: bool) -> void:
	enabled = value


## The three authority ceilings as the resolver wants them. Methods rather than the
## fields, because the reader is asking "how much of your group may I let it use",
## and the answer is only meaningful together with the matching `along`/`lateral`/
## `spin` request - a scale without its direction is a number nothing can spend.
func retro_authority() -> float:
	return retro_scale


func strafe_authority() -> float:
	return strafe_scale


func rotation_authority() -> float:
	return rotation_scale


## The lines the diagnostics print, kept as text here so a headless run can read the
## assist's state without a renderer - same arrangement as the engine plant.
func report() -> Array[String]:
	var p := settings()
	return [
		"stab       %s  auth %.2f" % ["ON" if enabled else "OFF", authority],
		"stab resid %6.1f px/s  dead %.1f" % [residual, p.stabilization_dead_zone],
		"stab borrow retro %.2f slide %.2f spin %.2f" % [
			retro_scale, strafe_scale, rotation_scale],
	]


func settings() -> ShipAssistParameters:
	if parameters == null:
		parameters = ShipAssistParameters.new()
	return parameters


## How much of a group the stabilizer may borrow: the designer's fraction, cut down so
## that `fraction * group_acceleration` never exceeds the px/s^2 the assist is
## allowed to command. At the shipped defaults both caps bind, which is the point -
## one number per axis is what a designer feels when tuning.
func _borrow(fraction: float, ceiling: float, group: float) -> float:
	if group <= 0.0:
		return 0.0
	return clampf(minf(fraction, ceiling / group), 0.0, 1.0)


## The same argument in rad/s^2. The passive damping spends part of the assist's
## total ceiling before a vernier lights, so only what is left of
## `stabilization_max_angular_correction` can be borrowed from the rudder's authority.
func _borrow_turn(fraction: float, ceiling: float) -> float:
	var group := _angular_group()
	if group <= 0.0:
		return 0.0
	var left := ceiling - _passive_angular()
	if left <= 0.0:
		return 0.0
	return clampf(minf(fraction, left / group), 0.0, 1.0)


# The four numbers the assist needs from the hull, read live through the back-link so
# they are the *exported* values: re-tune `braking_acceleration` in the inspector and
# the stabilizer's borrow moves with it, instead of keeping a copy that lies.
func _retro_group() -> float:
	return ship.braking_acceleration


func _maneuvering_group() -> float:
	return ship.settings().maneuvering_engine_power


func _angular_group() -> float:
	return ship.angular_acceleration


func _passive_angular() -> float:
	return ship.angular_deceleration


func _angular_stop() -> float:
	return ship.angular_stop_threshold
