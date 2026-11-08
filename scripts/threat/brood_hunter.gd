extends Node2D
class_name BroodHunter

## One of the brood: the small, close danger the creature sends after a loud
## ship. It is the only thing in the demo that can hurt the hull on purpose.
##
## It is meant to be avoided, not fought - the ship has no weapons:
##
##   * it hunts what sounds like a hull: a decoy in range is chased instead of
##     the ship, and a hunter that reaches a decoy feeds on it and dissolves;
##   * a burning flare blinds it: it recoils from the light and loses time;
##   * it is slower than a ship under full thrust, and it gives up after a
##     while or when the ship gets far enough away.
##
## When it is close enough it charges its beam (the attack animation) and the
## beam lands only if the ship is still in reach when it fires.

enum State { EMERGE, HUNT, ATTACK, LURED, STUNNED, LEAVE, DYING }

const GROUP := "brood"
const WORLD_PAUSABLE_GROUP := "world_pausable"
const FRAMES_DIR := "res://assets/threats/brood/"
const ANIMS := {"idle": 4, "move": 4, "attack": 4, "hit": 4, "death": 6}
## How close a hunter comes before it circles instead of closing in.
const STAND_OFF := 300.0

static var _frames: SpriteFrames = null

@export var max_speed: float = 290.0
@export var lured_speed: float = 380.0
@export var accel: float = 420.0
@export var attack_range: float = 430.0
@export var beam_reach: float = 560.0
@export var beam_damage: float = 0.06
@export var attack_cooldown: float = 3.4
@export var lifetime: float = 42.0
@export var give_up_distance: float = 3600.0
@export var decoy_sense: float = 1700.0
@export var flare_fear: float = 520.0

signal died()

var _state: int = State.EMERGE
var _vel: Vector2 = Vector2.ZERO
var _age: float = 0.0
var _state_t: float = 0.0
var _cooldown: float = 1.5
var _fired: bool = false
var _beam_t: float = 0.0
var _beam_to: Vector2 = Vector2.ZERO
var _decoy: Node2D = null
var _sprite: AnimatedSprite2D


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(WORLD_PAUSABLE_GROUP)
	z_index = 3
	_sprite = AnimatedSprite2D.new()
	_sprite.sprite_frames = _shared_frames()
	_sprite.scale = Vector2.ONE * 0.95
	_sprite.modulate.a = 0.0
	add_child(_sprite)
	_sprite.play("move")
	GameFeed.sfx(get_tree(), "brood_emerge", global_position)


static func _shared_frames() -> SpriteFrames:
	if _frames != null:
		return _frames
	_frames = SpriteFrames.new()
	_frames.remove_animation("default")
	for anim in ANIMS:
		_frames.add_animation(anim)
		_frames.set_animation_speed(anim, 9.0 if anim != "death" else 8.0)
		_frames.set_animation_loop(anim, anim in ["idle", "move"])
		for i in int(ANIMS[anim]):
			var tex := load("%s%s_%d.png" % [FRAMES_DIR, anim, i]) as Texture2D
			if tex != null:
				_frames.add_frame(anim, tex)
	return _frames


func state() -> int:
	return _state


func is_alive() -> bool:
	return _state != State.DYING


func _physics_process(delta: float) -> void:
	_age += delta
	_state_t += delta
	_cooldown = maxf(_cooldown - delta, 0.0)
	_beam_t = maxf(_beam_t - delta, 0.0)
	var ship := _ship()
	if ship == null:
		return
	var to_ship := ship.global_position - global_position
	var dist := to_ship.length()

	match _state:
		State.EMERGE:
			_sprite.modulate.a = clampf(_state_t / 1.2, 0.0, 1.0)
			_steer(to_ship, max_speed * 0.6, delta)
			if _state_t >= 1.2:
				_go(State.HUNT)
		State.HUNT:
			if _check_flare() or _check_decoy():
				return
			if _hull_lost(ship):
				_go(State.LEAVE)
				return
			# close in to beam range, then circle there instead of sitting on the hull
			var want := to_ship
			if dist < STAND_OFF:
				want = -to_ship.normalized() * 0.6 + to_ship.orthogonal().normalized()
			_steer(want, max_speed, delta)
			if dist < attack_range and _cooldown <= 0.0:
				_go(State.ATTACK)
			elif _age > lifetime or dist > give_up_distance:
				_go(State.LEAVE)
		State.ATTACK:
			_vel = _vel.move_toward(Vector2.ZERO, accel * 2.0 * delta)
			_face(to_ship)
			if not _fired and _sprite.frame >= 3:
				_fired = true
				_beam_to = ship.global_position
				_beam_t = 0.25
				if dist <= beam_reach:
					_hit_ship(ship)
				GameFeed.sfx(get_tree(), "brood_attack", global_position)
			if _state_t > 0.75:
				_cooldown = attack_cooldown
				_go(State.HUNT)
		State.LURED:
			if _decoy == null or not is_instance_valid(_decoy) or not bool(_decoy.call("is_active")):
				_decoy = null
				_go(State.HUNT)
			else:
				var to_decoy := _decoy.global_position - global_position
				_steer(to_decoy, lured_speed, delta)
				if to_decoy.length() < 70.0:
					_decoy.call("consume")
					_decoy = null
					_go(State.DYING)
		State.STUNNED:
			_vel = _vel.move_toward(Vector2.ZERO, accel * delta)
			if _state_t > 2.2:
				_go(State.HUNT)
		State.LEAVE:
			_steer(-to_ship, max_speed, delta)
			_sprite.modulate.a = clampf(1.0 - _state_t / 2.5, 0.0, 1.0)
			if _state_t > 2.5:
				queue_free()
		State.DYING:
			_vel = _vel.move_toward(Vector2.ZERO, accel * delta)
			if _state_t > 1.4:
				died.emit()
				queue_free()
	global_position += _vel * delta
	queue_redraw()


func _go(next: int) -> void:
	_state = next
	_state_t = 0.0
	match next:
		State.HUNT, State.LURED, State.LEAVE:
			_sprite.play("move")
		State.ATTACK:
			_fired = false
			_sprite.play("attack")
		State.STUNNED:
			_sprite.play("hit")
		State.DYING:
			_sprite.play("hit")
			_sprite.animation_finished.connect(func() -> void:
				if _state == State.DYING:
					_sprite.play("death"), CONNECT_ONE_SHOT)
			GameFeed.sfx(get_tree(), "brood_die", global_position)


func _steer(dir: Vector2, speed: float, delta: float) -> void:
	if dir == Vector2.ZERO:
		return
	_vel = _vel.move_toward(dir.normalized() * speed, accel * delta)
	_face(_vel)


## The sprite's front is its +Y edge.
func _face(dir: Vector2) -> void:
	if dir.length() < 1.0:
		return
	_sprite.rotation = lerp_angle(_sprite.rotation, dir.angle() - PI * 0.5, 0.2)


## A decoy sounds like a hull: if one is close, it wins.
func _check_decoy() -> bool:
	var best: Node2D = null
	var best_d := decoy_sense
	for node in get_tree().get_nodes_in_group("decoy"):
		var decoy := node as Node2D
		if decoy == null or not decoy.has_method("is_active") or not bool(decoy.call("is_active")):
			continue
		var d := decoy.global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = decoy
	if best == null:
		return false
	_decoy = best
	_go(State.LURED)
	return true


## A burning flare close by blinds it.
func _check_flare() -> bool:
	for node in get_tree().get_nodes_in_group("flare"):
		var flare := node as Node2D
		if flare == null or not flare.has_method("is_burning") or not bool(flare.call("is_burning")):
			continue
		var away := global_position - flare.global_position
		if away.length() < flare_fear:
			_vel = away.normalized() * max_speed
			_go(State.STUNNED)
			return true
	return false


func _hit_ship(ship: Node2D) -> void:
	var systems := ship.get_node_or_null("Systems")
	if systems != null and systems.has_method("apply_hull_damage"):
		systems.call("apply_hull_damage", beam_damage, "brood")
	GameFeed.shake(get_tree(), 10.0, 0.35)


func _ship() -> Node2D:
	return GameNodes.ship(get_tree())


func _draw() -> void:
	if _beam_t <= 0.0:
		return
	var to := to_local(_beam_to)
	var a := _beam_t / 0.25
	draw_line(Vector2.ZERO, to, Color(1.0, 0.15, 0.1, 0.35 * a), 18.0)
	draw_line(Vector2.ZERO, to, Color(1.0, 0.6, 0.5, 0.9 * a), 4.0)
	draw_circle(to, 26.0 * a, Color(1.0, 0.3, 0.2, 0.5 * a))


func _hull_lost(ship: Node2D) -> bool:
	var systems := ship.get_node_or_null("Systems")
	return systems != null and systems.has_method("is_hull_destroyed") and bool(systems.call("is_hull_destroyed"))
