extends Node2D
## Throwaway ship used only to review the background system.
## Deliberately not the game's controller: it flies freely through an unbounded
## world so parallax and the generator can be watched.
##
## Keys:  WASD / arrows fly, Shift boost
##        T / G  seed +1 / -1        R  random seed
##        1..6  toggle each band     C  camera-driven <-> velocity-driven
##        PageUp / PageDown  speed x1.25

@export var max_speed := 520.0
@export var acceleration := 1500.0
@export var deceleration := 700.0
@export var turn_responsiveness := 9.0
@export var boost_multiplier := 1.65
@export var speed_multiplier := 1.0

var velocity := Vector2.ZERO
var _thrust := 0.0
var _tick := 0.0

@onready var background: Node = get_node_or_null("../Background")
@onready var sprite: Sprite2D = $Sprite2D
@onready var readout: Label = get_node_or_null("../HUD/Readout")


func _ready() -> void:
	add_to_group("player")


func _physics_process(delta: float) -> void:
	var input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var cap := max_speed * speed_multiplier
	if Input.is_action_pressed("boost"):
		cap *= boost_multiplier

	if input != Vector2.ZERO:
		velocity = velocity.move_toward(input * cap, acceleration * delta)
		rotation = lerp_angle(rotation, velocity.angle(), 1.0 - exp(-turn_responsiveness * delta))
	else:
		velocity = velocity.move_toward(Vector2.ZERO, deceleration * delta)

	position += velocity * delta
	_thrust = move_toward(_thrust, 1.0 if input != Vector2.ZERO else 0.0, delta * 5.0)
	if sprite != null:
		sprite.modulate = Color(0.78, 0.88, 1.0, 0.5 + 0.5 * maxf(0.4, _thrust))


func _process(delta: float) -> void:
	if background == null:
		return
	# only hand the velocity over when the rig is told to listen to it
	if background.drive_mode == background.DriveMode.VELOCITY_ONLY:
		background.set_player_velocity(velocity)
	_tick += delta
	if _tick > 0.25:
		_tick = 0.0
		_update_readout()


func _update_readout() -> void:
	if readout == null or not background.has_method("stats"):
		return
	var st: Dictionary = background.stats()
	readout.text = "seed %d   bands %d   nodes %d   chunks %d\npos %.0f, %.0f   vel %.0f   fps %d" % [
		st.get("seed", 0), st.get("bands", 0), st.get("nodes", 0), st.get("chunks", 0),
		position.x, position.y, velocity.length(), Engine.get_frames_per_second()]


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or background == null:
		return
	if not background.has_method("set_seed"):
		return
	var s: int = background.get_seed()
	match event.keycode:
		KEY_T:
			background.set_seed(s + 1)
		KEY_G:
			background.set_seed(s - 1)
		KEY_R:
			background.set_seed(int(Time.get_ticks_msec()) ^ 0x5EED)
		KEY_1:
			background.show_base = not background.show_base
		KEY_2:
			background.show_nebula = not background.show_nebula
		KEY_3:
			background.show_distant_stars = not background.show_distant_stars
		KEY_4:
			background.show_midground = not background.show_midground
		KEY_5:
			background.show_near_objects = not background.show_near_objects
		KEY_6:
			background.show_anomalies = not background.show_anomalies
		KEY_C:
			if background.drive_mode == background.DriveMode.AUTO:
				background.drive_mode = background.DriveMode.VELOCITY_ONLY
			else:
				background.drive_mode = background.DriveMode.AUTO
		KEY_PAGEUP:
			speed_multiplier = clampf(speed_multiplier * 1.25, 0.1, 16.0)
		KEY_PAGEDOWN:
			speed_multiplier = clampf(speed_multiplier / 1.25, 0.1, 16.0)
		_:
			return
	get_viewport().set_input_as_handled()
