extends RigidBody2D
class_name SpaceDebris

## One loose fragment of unknown manufactured origin. The stream's own salt and
## chunk seed place it in the world; this scene only supplies the picture, a
## conservative circular hull and the shared world-object interface. It is a live
## body like a rock is: parked until something hits it, then carried by whatever
## the meeting gave it.

const ART_DIR := "res://assets/world/debris/"
## Cached textures per shape name to avoid repeated load() on pooled reuse.
static var _texture_cache := {}

var shape := "01"
var px_scale := 1.0
var extent := 0.0

@onready var sprite: Sprite2D = $Sprite
@onready var hull: CollisionShape2D = $Hull


func _ready() -> void:
	add_to_group("debris")
	add_to_group("obstacle")


func world_object_kind() -> String:
	return WorldObjects.KIND_DEBRIS


func world_object_info() -> Dictionary:
	return {
		"title": "debris_%s" % shape,
		"shape": shape,
		"px_scale": px_scale,
		"extent": extent,
		"mass": mass,
	}


func reach_toward(dir: Vector2) -> float:
	var local := dir.rotated(-global_rotation)
	return extent * maxf(absf(local.normalized().x), absf(local.normalized().y))


func set_form(which: String, scale_px: float, color: Color) -> void:
	shape = which
	px_scale = scale_px
	# a pooled body starts its new life at rest, or it would arrive in the next
	# chunk still carrying the shove it got in the last one
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	var name := "debris_" + shape
	var texture: Texture2D = _texture_cache.get(name)
	if texture == null:
		texture = load(ART_DIR + name + ".png") as Texture2D
		if texture == null:
			push_error("no debris art for %s.png" % name)
			return
		_texture_cache[name] = texture
	sprite.texture = texture
	sprite.scale = Vector2(px_scale, px_scale)
	sprite.modulate = color
	# A manufactured shard is not a perfect disc, but a circular hull is honest,
	# cheap and never lets the ship clip through the painted middle.
	extent = maxf(texture.get_width(), texture.get_height()) * 0.5 * px_scale
	var circle := hull.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		hull.shape = circle
	circle.radius = maxf(extent * 0.62, 4.0)
	mass = clampf(extent * 0.025, 0.5, 12.0)
