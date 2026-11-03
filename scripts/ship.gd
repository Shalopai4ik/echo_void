extends Node2D

## Ship flight controller.
## WASD (or arrow keys) set the direction, the fighter banks toward it.
## Hold Shift to boost. The world is unbounded: the Camera2D child keeps the
## ship centred and the parallax background streams past in every direction.
## The Hull area is what makes the asteroid belt solid - the controller stays
## kinematic and decides for itself how a collision changes its velocity. Enough
## closing speed breaks the rock and the ship keeps most of what it had; not
## enough of it and the ship bounces off instead.
##
## What a meeting costs each side is shared out by mass, so a pebble chips the
## shield and a boulder hits it. The shield soaks damage first and climbs back
## after a clean run; the hull does not come back on its own.
##
## Everything the eye follows - the airframe, the exhaust, the sparks - is under
## `Visuals`, and everything the world touches - `Hull` and the camera - is not.
## That split is what lets the ship roll over into a turn, ring from a hit and
## breathe at rest without any of it moving a single collision vertex.

@export_group("Flight")
## Doubled with the 0.5 camera zoom: the world is twice as wide on screen, so the
## fighter has to cross twice the pixels to look as quick as it did.
@export var max_speed: float = 1040.0
@export var acceleration: float = 3600.0
@export var deceleration: float = 1800.0
@export var turn_responsiveness: float = 9.0
@export var boost_multiplier: float = 1.65

@export_group("Collision")
## Half-extents of the drawn fighter in world pixels: the hull reaches further
## along the nose than across the wings, and the contact test follows that.
@export var hull_reach: Vector2 = Vector2(141, 93)
## How hard the ship is shoved back out of a rock it hits, before the rock's
## share of the mass scales it down. A velocity, so it scales with `max_speed`.
@export var impact_push: float = 240.0
## Worst case of a breakthrough: the fraction of speed left after smashing the
## heaviest rock the belt rolls. Lighter ones cost proportionally less.
@export_range(0.0, 1.0) var breakthrough: float = 0.82
## Fraction of an impact the ship survives intact when the rock did break.
@export_range(0.0, 1.0) var breakthrough_damage: float = 0.3

@export_group("Damage")
## How heavily the fighter is built. Against a rock of mass m the ship takes
## ship_mass / (m + ship_mass) of the meeting, so the bigger the stone the more
## of the impact it hands back.
@export var ship_mass: float = 6.0
## Damage a dead-ahead boulder ram at full cruise takes off the ship. Measured in
## points, not in pixels per second: the impact is scaled by `closing / max_speed`
## below, so retuning the flight speed no longer retunes the balance behind your
## back.
@export var ram_damage: float = 26.0
@export_range(0, 500) var shield_max: float = 100.0
@export_range(0, 500) var hull_max: float = 100.0
## Seconds of flying clean before the shield starts climbing back, and how fast.
@export var shield_regen_delay: float = 4.0
@export var shield_regen_rate: float = 18.0
## There is no rescue service out here, so the reactor restarts itself. Change
## `emergency_restart` to 0 to leave the ship dead instead.
@export var emergency_restart: float = 4.0
@export_range(0.0, 1.0) var restart_hull: float = 0.3

const ENGINE_SCALE := 2.0
## Where the nozzles sit on the drawn airframe, in the Player's own pixels: the
## nozzle mouth of fighter.png sits at -141 (tail col 3 on a 148 px texture), so
## the exhaust starts there.
const NOZZLE := Vector2(-141, 0)
## How far the fighter actually rolls over into a turn, in radians. The sprite is
## compressed by cos of this, so it is also how thin the wings go at full bank.
const BANK_MAX := 0.9
## Yaw rate, in rad/s, that holds the ship at that full bank. A course change at
## cruise only ever swings the velocity vector at ~3 rad/s, so this is set there:
## a lazy correction gets a lazy roll and a hard turn saturates it.
const BANK_RATE := 2.6
## How far the airframe drifts fore and aft while it sits idle, in texture pixels.
const IDLE_BOB := 1.4

signal status_changed(shield_ratio: float, hull_ratio: float, destroyed: bool)

var velocity := Vector2.ZERO
var shield := 0.0
var hull := 0.0
var destroyed := false

var _thrust := 0.0
var _boost := 0.0
var _clean := 0.0
var _dead := 0.0
var _rpm := 0.0
var _turn := 0.0
var _prev_rot := 0.0
## 1.0 the instant the reactor lights, and falling: the over-shoot that makes
## lighting off read as an event instead of a sprite switching on.
var _flare := 0.0
var _burning := false
## How hard the airframe is still ringing after a hit, and which way it was leaned.
var _shake := 0.0
var _jolt := Vector2.UP
var _bank := 0.0
var _time := 0.0

@onready var visuals: Node2D = $Visuals
@onready var sprite: Sprite2D = $Visuals/Sprite2D
@onready var bank_mat: ShaderMaterial = sprite.material as ShaderMaterial
@onready var hull_area: Area2D = $Hull
@onready var plume: Sprite2D = $Visuals/EnginePlume
@onready var core: Sprite2D = $Visuals/EngineCore
@onready var glow: Sprite2D = $Visuals/EngineGlow
@onready var sparks: CPUParticles2D = $Visuals/ExhaustSparks
@onready var smoke: CPUParticles2D = $Visuals/DamageSmoke


func _ready() -> void:
	add_to_group("player")
	shield = shield_max
	hull = hull_max
	plume.position = NOZZLE
	core.position = NOZZLE + Vector2(3, 0)
	glow.position = NOZZLE + Vector2(-14, 0)
	sparks.position = NOZZLE + Vector2(-10, 0)
	smoke.emitting = false
	_publish()


func _physics_process(delta: float) -> void:
	var input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if destroyed:
		input = Vector2.ZERO
		_revive(delta)
	else:
		_regen_shield(delta)

	var speed_cap := max_speed
	if Input.is_action_pressed("boost"):
		speed_cap *= boost_multiplier

	if input != Vector2.ZERO:
		velocity = velocity.move_toward(input * speed_cap, acceleration * delta)
		var target_angle := velocity.angle()
		rotation = lerp_angle(rotation, target_angle, 1.0 - exp(-turn_responsiveness * delta))
	else:
		velocity = velocity.move_toward(Vector2.ZERO, deceleration * delta)

	position += velocity * delta
	_resolve_rocks()

	var thrust_target := 1.0 if input != Vector2.ZERO else clampf(velocity.length() / max_speed, 0.0, 1.0)
	if destroyed:
		thrust_target = 0.0
	_thrust = move_toward(_thrust, thrust_target, delta * 5.0)

	var boosting := input != Vector2.ZERO and Input.is_action_pressed("boost")
	_boost = move_toward(_boost, 1.0 if boosting else 0.0, delta * 6.0)

	_turn = lerpf(_turn, wrapf(rotation - _prev_rot, -PI, PI) / maxf(delta, 1e-5),
		1.0 - exp(-18.0 * delta))
	_prev_rot = rotation

	_time += delta
	_update_bank(delta)
	_update_engine(delta)
	_update_jitter(delta)
	_show_wear()


## Rocks are bodies, the hull is an area, so nothing is resolved by the physics
## engine: the ship is steered, not simulated. This pushes it back out of
## whatever it is inside and shares the impact out by mass.
func _resolve_rocks() -> void:
	for body in hull_area.get_overlapping_bodies():
		var rock := body as EchoAsteroid
		if rock == null:
			continue
		var d := rock.global_position - global_position
		var dist := d.length()
		if dist < 0.001:
			continue
		var n := d / dist
		var e := n.rotated(-rotation)
		var sx := e.x / hull_reach.x
		var sy := e.y / hull_reach.y
		var reach := 1.0 / sqrt(maxf(sx * sx + sy * sy, 1e-6))
		var sink := reach + rock.extent_toward(-n) - dist
		if sink > 0.0:
			global_position -= n * sink
		var closing := n.dot(velocity)
		if closing <= 0.0 or destroyed:
			continue

		# how hard this hit is, told as a fraction of full cruise rather than in
		# pixels per second, so every damage number in the project survives a
		# change of `max_speed`
		var force := closing / max_speed
		var mass := rock.mass
		var share := mass / (mass + ship_mass)
		var result := rock.take_hit(force, Input.is_action_pressed("boost"), n)
		var shattered := result == EchoAsteroid.Hit.SHATTERED
		if shattered:
			# through it. A pebble barely scrubs you; the toll grows with the size
			# of the rock that had to come apart in front of the ship.
			var light := 1.0 - mass / EchoAsteroid.MAX_MASS
			velocity *= clampf(breakthrough + (1.0 - breakthrough) * light,
				breakthrough, 0.97)
		else:
			var shove := closing * ship_mass / (mass + ship_mass)
			rock.knock(n * shove * mass, signf(n.cross(velocity)))
			velocity = velocity.slide(n) * (1.0 - 0.45 * share) - n * impact_push * share
		take_damage(force * share * ram_damage * (breakthrough_damage if shattered else 1.0), -n)


## The shield soaks what it can; the rest is the hull's problem. `from` is the
## direction the blow came out of, and the airframe rings along it.
func take_damage(energy: float, from := Vector2.ZERO) -> void:
	if destroyed or energy <= 0.0:
		return
	var left := energy
	if shield > 0.0:
		var soaked := minf(shield, left)
		shield -= soaked
		left -= soaked
	hull = maxf(hull - left, 0.0)
	_clean = 0.0
	_shake = clampf(_shake + energy / maxf(ram_damage, 1.0), 0.0, 1.0)
	if from != Vector2.ZERO:
		_jolt = from.normalized()
	if hull <= 0.0:
		destroyed = true
		_dead = 0.0
		_shake = 1.0
	_publish()


func shield_ratio() -> float:
	return clampf(shield / shield_max, 0.0, 1.0) if shield_max > 0.0 else 0.0


func hull_ratio() -> float:
	return clampf(hull / hull_max, 0.0, 1.0) if hull_max > 0.0 else 0.0


func _regen_shield(delta: float) -> void:
	_clean += delta
	if _clean < shield_regen_delay or shield >= shield_max:
		return
	shield = minf(shield + shield_regen_rate * delta, shield_max)
	_publish()


func _revive(delta: float) -> void:
	if emergency_restart <= 0.0:
		return
	_dead += delta
	if _dead < emergency_restart:
		return
	shield = shield_max
	hull = hull_max * restart_hull
	destroyed = false
	_clean = 0.0
	_publish()


func _publish() -> void:
	status_changed.emit(shield_ratio(), hull_ratio(), destroyed)


## A wounded fighter reads as wounded: a little of the hull's own red bleeds into
## the paint as the shield falls away, a fresh hit flashes white and fades back,
## and a ship hurt enough to be dying starts bleeding gas out of itself. A wreck
## does not flash - the blow that finished it is the last thing it was lit by.
func _show_wear() -> void:
	var hurt := 1.0 - hull_ratio() * (0.5 + 0.5 * shield_ratio())
	var tint := Color(1.0, 1.0, 1.0).lerp(Color(0.92, 0.5, 0.44), hurt * 0.35)
	if not destroyed:
		tint = tint.lerp(Color(1.6, 1.55, 1.45), _shake * _shake * 0.5)
	sprite.modulate = tint
	smoke.emitting = hull_ratio() < 0.55 or destroyed


## The fighter rolls into every turn and rolls back out of it. Only the drawn
## airframe and its exhaust sit under Visuals, so the collision hull keeps the
## full wingspan while the paint goes edge-on.
func _update_bank(delta: float) -> void:
	_bank = lerpf(_bank, clampf(_turn / BANK_RATE, -1.0, 1.0), 1.0 - exp(-14.0 * delta))
	visuals.scale = Vector2(1.0, cos(_bank * BANK_MAX))
	bank_mat.set_shader_parameter("bank", _bank)


## A hit leaves the airframe ringing along the line it came from, and a ship that
## is just sitting there drifts a pixel or two so it never reads as a decal.
func _update_jitter(delta: float) -> void:
	_shake = move_toward(_shake, 0.0, delta * 3.0)
	visuals.position = _jolt * sin(_time * 74.0) * _shake * _shake * 5.0
	sprite.position = Vector2(0.0, sin(_time * 1.7) * IDLE_BOB) * (1.0 - _thrust)


## The reactor is never steady. A fast flicker rides on the plume's length and a
## slower swell on its width, so the two never come back into step; the whole
## column lags a beat behind a turn, because the ship changes attitude faster than
## the exhaust behind it can. Lighting off over-shoots, boosting stretches the
## flame and floods the halo, and the plume narrows with the wings when the ship
## rolls, because it is bolted to the same airframe.
func _update_engine(delta: float) -> void:
	_rpm += delta * (6.5 + 15.0 * _boost)
	var burning := _thrust > 0.02
	if burning and not _burning:
		_flare = 1.0
	_burning = burning
	_flare = move_toward(_flare, 0.0, delta * 3.2)

	plume.visible = burning
	core.visible = burning
	glow.visible = burning
	sparks.emitting = _boost > 0.25 or (_thrust > 0.85 and not destroyed)
	if not burning:
		return

	var flick := 0.88 + 0.12 * sin(_rpm * 9.3) + 0.05 * sin(_rpm * 22.7 + 1.7)
	var swell := 0.94 + 0.06 * sin(_rpm * 3.1)
	var stutter := 0.92 + 0.08 * sin(_rpm * 17.1 + 2.2)
	var flare := 1.0 + 1.2 * _flare
	var length := (0.22 + 0.78 * _thrust) * flick * (1.0 + 0.62 * _boost) * flare
	var width := (0.52 + 0.48 * _thrust) * swell * (1.0 + 0.12 * _boost)
	var wag := clampf(-_turn * 0.010, -0.22, 0.22)

	plume.scale = Vector2(ENGINE_SCALE * length, ENGINE_SCALE * width * stutter)
	plume.rotation = wag
	plume.modulate = Color(1, 1, 1, 0.30 + 0.70 * _thrust)

	core.scale = Vector2(ENGINE_SCALE * (0.45 + 0.55 * _thrust) * flick * flare,
		ENGINE_SCALE * (0.72 + 0.28 * _thrust) * swell)
	core.rotation = wag * 0.35
	core.modulate = Color(1, 1, 1, clampf(0.35 + 0.65 * _thrust + 0.3 * _flare, 0.0, 1.0))

	glow.scale = Vector2(1.5 * (0.6 + 0.4 * _thrust) * (1.0 + 0.5 * _boost) * flick,
		1.5 * (0.5 + 0.5 * _thrust) * swell * (1.0 + 0.6 * _flare))
	glow.rotation = wag * 0.6
	glow.modulate = Color(0.5, 0.85, 1.0,
		(0.08 + 0.42 * _boost + 0.10 * _thrust) * clampf(_thrust, 0.0, 1.0))
