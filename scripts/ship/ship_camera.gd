extends Camera2D
class_name ShipCamera

## Keeps the ship in the middle of the frame without ever snapping to it.
##
## The chase runs in `_process` as an exponential filter, so a course change
## costs the view a smooth correction and a bounce leaves it swimming rather than
## jolting. Godot's own position smoothing stays off: two filters on the same axis
## only ever fight.
##
## `top_level` is the important line in here. The camera hangs off the ship, which
## saves every follow calculation, but the ship yaws - without it the horizon would
## spin with every turn.
##
## Zoom is the engine's own scale, not a magnifier to invert: 2.0 draws the world
## twice as large as 1.0 does, 0.5 half as large. So the ends of the range are
## named by how much space the pilot is shown - `min_zoom` looks widest, `max_zoom`
## inspects closest - and nothing here has to be read backwards.

@export var target: Node2D
## 1/s of the gap closed. Tight enough that the ship reads as centred, loose
## enough that the void slides past instead of jerking.
@export_range(0.5, 30.0, 0.1) var follow_response: float = 6.0
## Widest look around and closest inspection the wheel is allowed to reach. The
## airframe is drawn at scale 2, so 0.5 is the 1:1 pixel view the art was made
## for; below it the pixels start swimming, above it the void stops reading as
## distance.
@export_range(0.1, 4.0, 0.01) var min_zoom: float = 0.3
@export_range(0.1, 6.0, 0.01) var max_zoom: float = 1.3
## Starting view, clamped into the range above.
@export_range(0.1, 4.0, 0.01) var base_zoom: float = 0.5
## Fractional step of one wheel notch, and how fast the view settles on it.
@export_range(0.01, 0.9) var zoom_step: float = 0.14
@export_range(1.0, 30.0, 0.1) var zoom_response: float = 8.0

var _view_zoom := 1.0


func _ready() -> void:
	top_level = true
	position_smoothing_enabled = false
	if target == null:
		target = get_parent() as Node2D
	_view_zoom = clampf(base_zoom, min_zoom, max_zoom)
	zoom = Vector2.ONE * _view_zoom
	if target != null:
		global_position = target.global_position


func _process(delta: float) -> void:
	if target == null:
		return
	var want := target.global_position
	global_position = global_position.lerp(want, 1.0 - exp(-follow_response * delta))
	if global_position.distance_to(want) < 0.05:
		global_position = want
	var settle := 1.0 - exp(-zoom_response * delta)
	zoom = zoom.lerp(Vector2.ONE * _view_zoom, settle)


func _unhandled_input(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel == null or not wheel.pressed:
		return
	if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
		zoom_in()
	elif wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		zoom_out()


## Put the view exactly on the ship, with no filter applied. A respawn, a
## cutscene placement or anything else that moves the ship in one jump needs this,
## because a four thousand pixel teleport would otherwise be spent as a second of
## blur while the chase caught up.
func snap() -> void:
	if target != null:
		global_position = target.global_position


## Closer to the ship: more pixels on the hull, less of the void around it.
func zoom_in(notches: float = 1.0) -> void:
	_aim(_view_zoom * pow(1.0 + zoom_step, notches))


## Further out: more of the void on screen, which is how a boulder is read as a
## hazard ahead of us instead of a wall in front of the lens.
func zoom_out(notches: float = 1.0) -> void:
	_aim(_view_zoom / pow(1.0 + zoom_step, notches))


## Absolute view scale, for scripted pulls later on. `Camera2D.set_zoom` is taken
## by the engine, so this one carries the name of what it actually changes.
func set_view_zoom(value: float) -> void:
	_aim(value)


func _aim(value: float) -> void:
	_view_zoom = clampf(value, min_zoom, max_zoom)
