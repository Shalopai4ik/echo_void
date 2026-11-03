extends RefCounted
class_name ShipState

## What the hull is doing, read back from what the hull is actually doing.
##
## Spec 3 asks for eight states and warns in the same breath against turning them into
## eight mutually exclusive modes - a ship can boost and turn and be stabilized at once,
## and a state machine that makes those three fight would have to pick a winner every
## frame and lose two. So this is the split the spec itself proposes:
##
## - `primary` is one value, the thing a listener would say if it had to say only one.
##   It is a *summary*, derived by a fixed precedence, and nothing in the ship is
##   switched off by it. It exists for HUDs, logs and an animation layer.
## - `flags` is a bitmask of every system genuinely working right now. Two, three or
##   five of them can be set at the same time, and that is the normal case, not an
##   error to resolve.
## - a *transient* is the collision: an event with a short hold, not a mode. It outranks
##   the burn states for `collision_state_hold` seconds and then gives the word back.
##
## Everything is read from the physics and the engine plant, never from the keys, which
## is the part spec 3.1 is insistent about. A hull with W released and 700 px/s still on
## it is not "stopped"; a stabilizer whose authority has faded to nothing is not
## "stabilizing"; an engine at 0.4 of its ramp is accelerating even though the pilot
## pressed the key a second ago. So the inputs are consulted only through what they
## produced: the plant's powers, the order's owners, and the body's own speeds.
##
## The state object writes nothing. It is not a node, it has no `_process`, and the only
## thing that comes out of it is a description - which is what keeps a reporting layer
## from becoming a second flight model wearing a hat.

enum State {
	NORMAL,
	ACCELERATING,
	BRAKING,
	EMERGENCY_BRAKING,
	BOOSTING,
	STABILIZING,
	COLLISION,
	DISABLED,
}

## The systems that can be working at the same time as any primary state.
const FLAG_MAIN := 1
const FLAG_RETRO := 2
const FLAG_ASTERN := 4
const FLAG_STRAFE := 8
const FLAG_ROTATION := 16
const FLAG_STABILIZER := 32
const FLAG_EMERGENCY := 64
const FLAG_BOOST := 128
const FLAG_EXTERNAL := 256

## The power floor at which a group counts as working. The same number the plant uses
## for `is_active`, so a flag and a drawn flame cannot disagree.
const ACTIVE_FLOOR := 0.02

var primary := State.NORMAL
var flags := 0

## Seconds left of the collision reaction window. Counted down here rather than
## timestamped, so a hull that pauses the tree does not hold a stale collision.
var hold_collision := 0.0

## The hull being described. Read-only from here: the state layer must never be able to
## reach back and change what it is reporting.
var ship: ShipController


func _init(owner: ShipController = null) -> void:
	ship = owner


## Called by the flight model once per physics frame, after the order is resolved and
## the plant has answered it, so every number read below is this frame's. Returns true
## when `primary` changed, which is what the ship turns into `ship_state_changed`.
func step(order: FlightOrder, delta: float) -> bool:
	flags = 0
	var plant = ship.engines
	if plant != null:
		if plant.main_power > ACTIVE_FLOOR:
			flags |= FLAG_MAIN
		if plant.brake_power > ACTIVE_FLOOR:
			flags |= FLAG_RETRO
		if plant.astern_power > ACTIVE_FLOOR:
			flags |= FLAG_ASTERN
		if absf(plant.strafe_power) > ACTIVE_FLOOR:
			flags |= FLAG_STRAFE
		if absf(plant.rotation_power) > ACTIVE_FLOOR:
			flags |= FLAG_ROTATION
	if ship.stabilization != null and ship.stabilization.authority > ACTIVE_FLOOR:
		flags |= FLAG_STABILIZER
	if ship.emergency_brake != null and ship.emergency_brake.engaged:
		flags |= FLAG_EMERGENCY
	if ship.boost != null and ship.boost.active:
		flags |= FLAG_BOOST
	if ship.external_acceleration.length_squared() > 0.0001:
		flags |= FLAG_EXTERNAL
	hold_collision = maxf(0.0, hold_collision - delta)

	var next := _primary(order)
	var changed := next != primary
	primary = next
	return changed


## The precedence, top down. The reasoning for the order is in the same order:
## a hull that cannot be flown is described by that first; a hull that has just been hit
## is described by the hit for as long as the reaction window says; then the linear
## retard, because "stopping" outranks "how"; then the engine; then the assist, which is
## the quietest thing on the ship and the one a listener can read off `flags` anyway.
func _primary(order: FlightOrder) -> int:
	if not ship.movement_enabled:
		return State.DISABLED
	if hold_collision > 0.0:
		return State.COLLISION
	if flags & FLAG_EMERGENCY != 0:
		return State.EMERGENCY_BRAKING
	if flags & FLAG_BOOST != 0:
		return State.BOOSTING
	if flags & FLAG_RETRO != 0 and order.retard != EngineController.Retard.ASTERN:
		return State.BRAKING
	if flags & (FLAG_MAIN | FLAG_ASTERN) != 0:
		return State.ACCELERATING
	if _borrowed_lever(order):
		return State.STABILIZING
	return State.NORMAL


## The stabilizer is the primary story only when it is the one holding a lever. While a
## pilot is flying with W and the assist merely takes the slide out, the honest word is
## ACCELERATING and the flag carries the rest.
func _borrowed_lever(order: FlightOrder) -> bool:
	return order.owner_retro == "stabilizer" or order.owner_strafe == "stabilizer" \
		or order.owner_rudder == "stabilizer"


## A collision just happened: the hull is described as reacting for the hold window.
func note_collision() -> void:
	hold_collision = settings().collision_state_hold


func settings() -> ShipWorldParameters:
	if ship != null and ship.world != null:
		return ship.world
	return ShipWorldParameters.new()


## The word a listener prints.
func name_of(state: int = -1) -> String:
	var value := primary if state < 0 else state
	return State.keys()[value]


## The flags as text, in the order a reader scans them.
func flags_text() -> String:
	var out := ""
	for pair in [["main", FLAG_MAIN], ["retro", FLAG_RETRO], ["astern", FLAG_ASTERN],
			["slide", FLAG_STRAFE], ["turn", FLAG_ROTATION],
			["stab", FLAG_STABILIZER], ["e-brake", FLAG_EMERGENCY],
			["boost", FLAG_BOOST], ["external", FLAG_EXTERNAL]]:
		if flags & pair[1] != 0:
			out += String(pair[0]) + " "
	return out.strip_edges() if out != "" else "none"


func has(flag: int) -> bool:
	return flags & flag != 0
