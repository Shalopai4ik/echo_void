extends Resource
class_name ShipEngineParameters

## The tuning surface of the engine plant (sub-stage 1.2).
##
## One resource, four groups of thrusters and the looks that go with them. This is
## the file the designer opens: nothing here moves the ship by itself - the flight
## model in `ship_controller.gd` still owns the accelerations and the ceilings it
## was built with in 1.1 - what this owns is how fast each group comes to life, how
## far it is allowed to go, and how the ship advertises that it is burning.
##
## Two kinds of number live here, and the difference matters:
##
## - The groups that already had a physical number in 1.1 (`forward_acceleration`,
##   `braking_acceleration`, `angular_acceleration` on the Ship) get a **0..1
##   authority ceiling** here. `main_engine_max_power = 1.0` means the engine can
##   ask for the whole of what the flight model is capable of; 0.6 means it is
##   throttled back. The physical number stays where it is, so the two sub-stages
##   never end up with two knobs for the same newton.
## - The lateral group is new in 1.2 and has no 1.1 counterpart, so its thrust
##   (`maneuvering_engine_power`, in px/s^2) and its ceiling (`max_lateral_speed`)
##   live here outright.
##
## Every `*_response_time` is the time the group takes to walk from zero power to
## full, and `main_engine_shutdown_time` the way back down. The ramps are linear,
## which is what makes them measurable: a burn held for exactly `response_time`
## seconds reaches full power on the last step of it.
##
## Assign this as a sub-resource on the Ship. Values left unwritten come from the
## defaults below, so the defaults are the shipping numbers, not a fallback.

@export_group("Main engine")
## Authority of the main engine over `forward_acceleration`, 0..1. At 1.0 the
## engine delivers the whole flight-model acceleration; the number exists so a
## later stage can throttle a damaged or upgraded reactor without touching the
## physics.
@export_range(0.0, 1.0, 0.01) var main_engine_max_power: float = 1.0
## Seconds from a cold start to full power. 0.35 s is slow enough that the ship
## leans into the burn rather than lurching, and it is the reason the exhaust has
## something to follow.
@export_range(0.01, 3.0, 0.01) var main_engine_response_time: float = 0.35
## Seconds to bleed back to zero after W is let go. Longer than the response time
## on purpose: the flame dying out behind a ship that has already stopped being
## pushed is the picture of cut engines, and the hull keeps every px/s it earned.
@export_range(0.01, 3.0, 0.01) var main_engine_shutdown_time: float = 0.5

@export_group("Braking engines")
## Authority of the retro burn over `braking_acceleration`, 0..1.
@export_range(0.0, 1.0, 0.01) var braking_engine_max_power: float = 1.0
## Seconds to full braking. Brakes bite faster than the main engine spools: 0.12 s,
## so the ship answers the lever inside a tenth of a second while the pilot is
## still reading the approach.
@export_range(0.01, 3.0, 0.01) var braking_engine_response_time: float = 0.12

@export_group("Maneuvering engines")
## Sideways thrust of the strafe pair, px/s^2. Deliberately under half of
## `forward_acceleration`: this is station-keeping authority, not a second way to
## go fast.
@export_range(0.0, 4000.0, 5.0, "suffix:px/s^2") var maneuvering_engine_power: float = 200.0
## Seconds to full lateral thrust.
@export_range(0.01, 3.0, 0.01) var maneuvering_engine_response_time: float = 0.15
## Ceiling of the sideways speed the strafe thrusters can hold. Like the forward
## ceiling it caps the thrusters and not the world: a bounce that throws the hull
## beam-on faster than this keeps its speed, and only `linear_drag` takes it back.
@export_range(0.0, 4000.0, 5.0, "suffix:px/s") var max_lateral_speed: float = 220.0

@export_group("Rotation engines")
## Authority of the yaw verniers over `angular_acceleration`, 0..1.
@export_range(0.0, 1.0, 0.01) var rotation_engine_power: float = 1.0
## Seconds to full rudder thrust. Shortest in the file: the nose has to answer the
## stick, and the *rate* ramp that makes the ship feel heavy is already in the
## flight model as `angular_acceleration`.
@export_range(0.01, 3.0, 0.01) var rotation_engine_response_time: float = 0.1

@export_group("Visuals")
## Brightness the jets are drawn at, multiplying each layer's alpha. Muted by
## default: this is a survey hull on a dark sky, not an arcade interceptor.
@export_range(0.0, 2.0, 0.01) var engine_glow_intensity: float = 1.0
## Seconds a jet takes to follow the power it is shown, up and down alike. Every
## group shares it, which is why a thruster coming on never flicks: the number is
## the fade, not the visibility test.
@export_range(0.0, 1.0, 0.01) var engine_effect_fade_time: float = 0.12
## Sparks per jet at full power. Small on purpose - four groups can burn at once,
## and this is the only place particles are allowed to multiply.
@export_range(0, 64, 1) var engine_particles_amount: int = 10
## Global multiplier of every jet's length, `flame_length` reborn as an engine
## parameter. The main nozzle is authored at 2.0 in the art's own frame.
@export_range(0.1, 3.0, 0.01) var engine_effect_scale: float = 1.0
