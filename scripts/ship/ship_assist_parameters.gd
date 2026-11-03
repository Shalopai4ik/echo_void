extends Resource
class_name ShipAssistParameters

## The tuning surface of the three flight assists (sub-stage 1.3).
##
## Stabilization, emergency braking and boost. Like `ShipEngineParameters`, this
## resource owns numbers and nothing else: no file in this set moves the hull. The
## flight model in `ship_controller.gd` is still the only place that integrates the
## ship, and the engine plant is still the only place that turns a request into a
## power. What is added here is *who is allowed to ask, how hard, and for how long*
## - which is exactly the difference between an assist and an autopilot.
##
## The three systems split the levers, they do not stack on top of them:
##
## - Stabilization borrows the retro, manoeuvring and rotation groups, and only for
##   the part of the lever the pilot is not already holding. Its numbers are
##   ceilings *below* the pilot's: `stabilization_max_linear_correction` is smaller
##   than `braking_acceleration`, `stabilization_max_lateral_correction` smaller
##   than `maneuvering_engine_power`. If those ever invert, the assist stops being
##   an assist and starts flying the ship by itself.
## - Emergency braking owns the linear retard for as long as it is held, and asks
##   for more than the pilot's S does (`emergency_brake_max_deceleration` above
##   `braking_acceleration`) - it is the one lever allowed to outrank W.
## - Boost scales the main engine's authority and nothing else. `boost_multiplier`
##   multiplies `main_engine_max_power`; the brake, manoeuvring and rotation groups
##   never see it.
##
## Every correction is capped twice on purpose: by a power (how much of a group's
## authority the assist may use) and by an acceleration (the most px/s^2 it may ever
## command). The power keeps it from being a second engine; the cap keeps a later
## tuning of the *engine* from silently making the assist brutal.

@export_group("Stabilization")
## Whether a hull starts its life with the stabilizer on. Default off: this is an
## inertial game, and the pilot deciding to hand the drift over is the point.
@export var stabilization_enabled_by_default: bool = false
## How much of the retro and manoeuvring groups the stabilizer may use, 0..1. At the
## shipped caps this is the number that binds on the sideways axis (0.7 × 200 = 140 =
## `stabilization_max_lateral_correction`) and the caps bind on the along axis, which
## is the arrangement the file's header describes: one number per axis to feel when
## tuning. Below about 0.5 the borrowed burn is so faint on screen that a pilot cannot
## tell the assist is working, and the whole point of 1.2's nozzle layer is lost.
@export_range(0.0, 1.0, 0.01) var stabilization_linear_power: float = 0.7
## How much of the yaw verniers the stabilizer may use, 0..1.
@export_range(0.0, 1.0, 0.01) var stabilization_angular_power: float = 0.7
## Seconds for the stabilizer's authority to come up from cold. It is what makes
## the system gradual: the same px/s^2 arriving in one frame would be a teleport
## with extra steps.
@export_range(0.01, 3.0, 0.01) var stabilization_response_time: float = 0.35
## Below this much speed - linear in px/s, angular in rad/s - there is nothing to
## correct. The dead zone is what stops the thrusters chattering at a hull that is
## already, for practical purposes, parked.
@export_range(0.0, 200.0, 0.5, "suffix:px/s") var stabilization_dead_zone: float = 18.0
## Ceiling of the sideways burn the stabilizer may command, px/s^2. Under
## `maneuvering_engine_power`, so a pilot on E always outranks the assist.
@export_range(0.0, 4000.0, 5.0, "suffix:px/s^2") var stabilization_max_lateral_correction: float = 140.0
## Ceiling of the retro burn the stabilizer may command along the nose, px/s^2.
## Under `braking_acceleration` for the same reason.
@export_range(0.0, 4000.0, 5.0, "suffix:px/s^2") var stabilization_max_linear_correction: float = 260.0
## Ceiling of the yaw correction, rad/s^2 *including* the hull's own passive
## `angular_deceleration`. This is the one cap that is deliberately above the pilot's
## rudder: the verniers and the passive damping add up, and a hull that keeps
## spinning after A is let go is the thing the stabilizer exists for.
@export_range(0.0, 60.0, 0.05, "radians_as_degrees") var stabilization_max_angular_correction: float = 9.0

@export_group("Emergency brake")
## The hardest deceleration the retro plant is allowed to deliver, px/s^2. S's
## `braking_acceleration` is the controlled burn; this is everything the nozzles
## have, which is why it is above it.
@export_range(0.0, 6000.0, 10.0, "suffix:px/s^2") var emergency_brake_max_deceleration: float = 1150.0
## Speed below which the emergency brake lets go rather than hunts. Above
## `velocity_stop_threshold`, so the flight model's rest snap always finishes the
## job the brakes started.
@export_range(0.0, 200.0, 0.5, "suffix:px/s") var emergency_brake_stop_threshold: float = 8.0
## Seconds to full retro authority. Shorter than the ordinary brakes' 0.12 s: the
## whole point of the key is that it answers on the frame it is pressed.
@export_range(0.01, 3.0, 0.01) var emergency_brake_response_time: float = 0.06

@export_group("Boost")
## The master switch. Off means the lever does nothing and the tank stops being
## touched - a hull without boost hardware should read that way in the panel too.
@export var boost_enabled: bool = true
## Charge the tank starts with, 0..1 of capacity. Capacity itself is 1.0 by
## definition: a later energy system owns the units, this system owns the ratio.
@export_range(0.0, 1.0, 0.01) var boost_charge: float = 1.0
## What the main engine's authority is multiplied by while boosting. Applied to the
## existing `main_engine_max_power`, never added as a separate acceleration.
@export_range(1.0, 4.0, 0.01) var boost_multiplier: float = 1.8
## What `max_forward_speed` is multiplied by while boosting. It only ever lifts the
## ceiling: a hull thrown faster than that by a bounce is never shaved down.
@export_range(1.0, 4.0, 0.01) var boost_max_speed_multiplier: float = 1.35
## Charge per second burned while the boost is actually pushing. 0.33 is about three
## seconds of boost from a full tank.
@export_range(0.0, 5.0, 0.01) var boost_drain_rate: float = 0.33
## Charge per second recovered once the delay has passed.
@export_range(0.0, 5.0, 0.01) var boost_recharge_rate: float = 0.14
## Seconds after the last burn before recovery starts. Without it the tank would
## refill while the lever was still held and the limit would be decorative.
@export_range(0.0, 10.0, 0.05) var boost_recharge_delay: float = 1.2
## Charge needed to light the boost, and - after the tank has run out - needed
## again before it can light. The second half is what stops a pilot from pumping
## the lever to spend a trickle of charge as a burst.
@export_range(0.0, 1.0, 0.01) var boost_min_activation_charge: float = 0.15
## Seconds for the extra authority to come in. The ramp is what makes 5.3's "no
## jump in velocity" true: an instantaneous 1.8x on a ship already at cruise is a
## step in acceleration the pilot feels as a shove.
@export_range(0.01, 3.0, 0.01) var boost_ramp_time: float = 0.22
