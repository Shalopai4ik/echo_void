extends Node2D
class_name SignalFlare

## The visible body of a signal light: a burning flare left where the pilot
## dropped it.
##
## It owns no signal - the ship's `ShipSignalLight` puts the broadcast on the
## air and takes it off - and no rules. It only burns: a hot core, a slow
## breathing halo and a radio ring that shows how far the signal reaches. It
## stops with the world when a panel is open and dies when its owner says so.

const WORLD_PAUSABLE_GROUP := "world_pausable"
const GROUP := "flare"

## How long the flare burns, seconds of game time.
var duration: float = 15.0
## The radius the signal reaches, drawn as a faint ring.
var radius_px: float = 600.0

var _time: float = 0.0
var _ends_at: float = 0.0
var _dying: float = -1.0


func _ready() -> void:
	add_to_group(WORLD_PAUSABLE_GROUP)
	add_to_group(GROUP)
	z_index = -1
	_ends_at = ShipSystemEvent.now() + maxf(duration, 0.1)


func _process(delta: float) -> void:
	_time += delta
	if _dying >= 0.0:
		_dying += delta
		if _dying >= 1.2:
			queue_free()
	elif ShipSystemEvent.now() >= _ends_at:
		extinguish()
	queue_redraw()


## Burn out: the light fades for a second and the node frees itself.
func extinguish() -> void:
	if _dying < 0.0:
		_dying = 0.0


func is_burning() -> bool:
	return _dying < 0.0


func _draw() -> void:
	var fade := 1.0 if _dying < 0.0 else clampf(1.0 - _dying / 1.2, 0.0, 1.0)
	var flicker := 0.82 + 0.18 * sin(_time * 23.0) * sin(_time * 7.3)
	var hot := Color(1.0, 0.55, 0.25)
	for i in 6:
		var r := 30.0 + float(i) * 26.0
		draw_circle(Vector2.ZERO, r, Color(hot.r, hot.g * 0.8, hot.b, 0.07 * fade * flicker))
	draw_circle(Vector2.ZERO, 9.0, Color(1.0, 0.9, 0.7, 0.95 * fade))
	draw_circle(Vector2.ZERO, 16.0, Color(1.0, 0.5, 0.2, 0.45 * fade * flicker))
	# the signal's own reach, a ring that keeps rolling outwards
	var roll := fmod(_time * 0.35, 1.0)
	draw_arc(Vector2.ZERO, radius_px * roll, 0.0, TAU, 96,
		Color(1.0, 0.45, 0.2, (1.0 - roll) * 0.22 * fade), 3.0)
	draw_arc(Vector2.ZERO, radius_px, 0.0, TAU, 128, Color(1.0, 0.45, 0.2, 0.06 * fade), 2.0)
