extends Resource
class_name ShipAudioParameters

## The tuning surface of the ship's sound (sub-stage 1.5).
##
## Like the three resources before it, this owns numbers and nothing else: the
## flight model integrates the hull, the engine plant owns the powers, and
## `ShipAudio` only turns those powers into a level. Nothing here can move the ship
## and nothing here knows a position, a velocity or a node.
##
## Two families of number live here:
##
## - **A level per sound category**, in decibels relative to the bus. Because the
##   engine layers are driven by a 0..1 power and converted with `linear_to_db`,
##   these are the loudness of a category at *full* power - a thruster at 20% is its
##   own level minus roughly 14 dB, so the sound follows the physics instead of
##   pretending to be at maximum. That is the consistency the spec asks for in 10.
## - **A response time per family**, in seconds. The loops are ramped with
##   `move_toward`, so a layer takes this long to reach full and the same time to
##   fall back to silence. It is what keeps a released W from clicking the hum off
##   and a boost from snapping in.
##
## The signal thresholds at the bottom are hysteresis, not physics: they only decide
## when a *short* system blip is allowed to fire, and every one of them is read from
## the live `BoostSystem` tank rather than from a private copy of it.

@export_group("Engine layers")
## The main engine at full power. Muted by design: this is a survey hull, not a
## fighter, and the hum is meant to sit under the player's attention for a whole
## session without becoming the thing they hear.
@export_range(-80.0, 6.0, 0.5) var main_volume_db: float = -7.0
## The retro plant (ordinary braking and astern) at full power.
@export_range(-80.0, 6.0, 0.5) var retro_volume_db: float = -11.0
## The manoeuvring pair. Quiet on purpose: lateral station-keeping is a texture,
## not a second engine, and the spec asks for no chattering on a held Q/E.
@export_range(-80.0, 6.0, 0.5) var strafe_volume_db: float = -18.0
## The yaw verniers, a little louder than the strafing pair because a turn is the
## input the player uses most and the layer doubles as feedback that the rudder bit.
@export_range(-80.0, 6.0, 0.5) var rotation_volume_db: float = -16.0
## The extra high-frequency boost component, layered on top of the main hum. It
## tracks the boost's own authority ramp, so the two rise and fall together.
@export_range(-80.0, 6.0, 0.5) var boost_volume_db: float = -11.0
## Extra gain on the retro layer while the emergency brake is hauling the hull down.
## The deceleration is already higher; this is the audible part of "harder than S".
@export_range(0.0, 12.0, 0.5) var emergency_extra_db: float = 3.0

@export_group("Impact and system levels")
## A HEAVY collision at full closing speed. The band's own share of this comes from
## how fast the two bodies met, so a LIGHT tap is this level minus about 18 dB.
@export_range(-80.0, 6.0, 0.5) var impact_volume_db: float = -4.0
## The short signals: stabilization on/off, boost on/low/empty/ready, control
## on/off, the boot chime. Deliberately the quietest family on the ship.
@export_range(-80.0, 6.0, 0.5) var system_volume_db: float = -13.0

@export_group("Response times")
## Seconds for a continuous engine layer to reach full, and to fall back to
## silence. Longer than the engine plant's own 0.35 s spool on purpose: the flame
## leads the sound by a frame or two, which is how a real turbine reads.
@export_range(0.01, 3.0, 0.01) var engine_fade_time: float = 0.45
## The verniers answer faster than the main engine - the nose is a direct command.
@export_range(0.01, 3.0, 0.01) var rotation_fade_time: float = 0.18
## The boost layer's own fade, matched to `boost_ramp_time` so the extra light and
## the extra sound arrive together.
@export_range(0.01, 3.0, 0.01) var boost_fade_time: float = 0.22
## Seconds for the main hum's pitch to follow its power. Slower than the level so a
## flick of the throttle reads as a swell rather than a wobble.
@export_range(0.01, 3.0, 0.01) var pitch_fade_time: float = 0.5

@export_group("Engine tone")
## Main hum pitch at idle and at full burn. A small span on purpose: pitch is
## seasoning here, and a hum that climbs an octave would read as a racing engine.
@export_range(0.5, 1.5, 0.01) var main_pitch_low: float = 0.88
@export_range(0.5, 1.5, 0.01) var main_pitch_high: float = 1.08
## Where the main hum's pitch is pulled while the boost is fully lit.
@export_range(0.5, 1.5, 0.01) var boost_pitch_high: float = 1.18

@export_group("Signal thresholds")
## Shortest gap, in seconds, between two impact sounds of any kind. A hull grinding
## along a boulder can raise several classified contacts a second; without this the
## mixer would be a woodpecker. The ship's own per-object cooldown is the first
## gate, this is the last one.
@export_range(0.0, 2.0, 0.01) var impact_min_interval: float = 0.12
## Shortest gap between two *different* system blips. Small, because the signals
## are already rare; it only stops a frame that flips two systems at once from
## stacking them on top of each other.
@export_range(0.0, 2.0, 0.01) var system_min_interval: float = 0.06
## Boost charge below which the "low tank" blip is allowed to fire. Read with
## hysteresis: the blip is armed again only once the tank climbs back well clear.
@export_range(0.0, 1.0, 0.01) var boost_low_charge: float = 0.25
## Charge at which the "tank usable again" blip fires after a depletion. Above
## `boost_min_activation_charge` on purpose - the point is that the player can light
## the boost again, not that the tank is full.
@export_range(0.0, 1.0, 0.01) var boost_ready_charge: float = 0.5
## Whether the hull makes a short boot signal when it comes up. A scene that starts
## mid-action (a cutscene, a reload) can switch this off in the inspector.
@export var play_boot_signal: bool = true