extends RigidBody2D
class_name StageRock

## A stone from the asteroid sheet, drawn and collided from the same outline.
##
## The collision piece is not hand-drawn: it comes out of
## `scripts/asteroid_shapes.gd`, which `tools/extract_asteroids.py` generated from
## the alpha of the art itself. Taking the silhouette from the same table the
## sprite is cut by is what keeps a ship stopped by a rock at the place where the
## rock is actually painted, and both halves follow `px_scale` together.
##
## The stone is a live body: it has no drive of its own and sits where the belt
## put it until something hits it, then it keeps whatever the meeting gave it.
## `mass` is a volume, so the same shove sends a pebble flying and barely leans a
## hill - see `set_form()`.

const SHAPES := preload("res://scripts/asteroid_shapes.gd")
const ART_DIR := "res://assets/asteroids/"
## Mass is volume, because that is what a hull actually meets: `extent` is the
## stone's radius in world pixels, so its cube is what puts a pebble and a hill
## three orders of magnitude apart instead of a factor of four. At MASS_REACH a
## stone weighs MASS_UNIT; the clamps keep a speck and a planetoid both sane.
const MASS_REACH := 34.0
const MASS_UNIT := 1.6
const MASS_MIN := 0.15
const MASS_MAX := 900.0
## A streamed field dresses dozens of bodies in the same second, and every one of
## them asks for the same twenty pictures, so the lookup is done once per shape.
static var _art := {}

@export_enum("01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11",
	"12", "13", "14", "15", "16", "17", "18", "19", "20") var shape := "04"
## Sprite scale, and with it the size of the obstacle: the source stones are
## 20-80 px, so 1.0 is a chunk and 3.5 is a hill.
@export_range(0.5, 6.0, 0.05) var px_scale: float = 2.0
## The sheet is cut for a hazy belt; on the bare black of a test map it reads too
## dim to trust as a hazard, so the tint is a lift as much as a colour - above 1
## brightens the stone rather than filtering it.
@export var tint := Color(1.2, 1.25, 1.35)

## The outline in local pixels and how far it reaches from the centre - the two
## numbers anything outside the rock needs in order to measure its clearance.
var piece := PackedVector2Array()
var extent := 0.0

@onready var sprite: Sprite2D = $Sprite
@onready var shape_node: CollisionPolygon2D = $Hull


## How this stone introduces itself to anything that asks. The ship's contact report
## (sub-stage 1.4) reads exactly these two answers, and a scanner will read the same
## ones: a hull can say what it hit - which outline, how big, how far it reaches - without
## knowing the name the scene happened to give the body, and without the flight model
## ever naming a rock.
func world_object_kind() -> String:
	return WorldObjects.KIND_ASTEROID


func world_object_info() -> Dictionary:
	return {
		"title": "asteroid_%s" % shape,
		"shape": shape,
		"px_scale": px_scale,
		"extent": extent,
		"mass": mass,
	}


func _ready() -> void:
	add_to_group("obstacle")
	set_form(shape, px_scale, tint)


## Dress the stone: picture and collision outline are read out of the same table,
## so the hull is always stopped where the rock is actually painted, and both
## halves follow one scale.
##
## The world field calls this again every time it takes a body back out of its
## pool, which is how one scene can be a pebble here and a hill there.
func set_form(which: String, scale_px: float, color: Color) -> void:
	shape = which
	px_scale = scale_px
	tint = color
	# A pooled body is handed a new life, not a continued one: the drift a rock
	# earned before it left the window belongs to the stone that left, not to the
	# one the field is putting down here.
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	piece.clear()
	extent = 0.0
	var name := "asteroid_" + shape
	var texture: Texture2D = _art.get(name)
	if texture == null:
		texture = load(ART_DIR + name + ".png") as Texture2D
		if texture == null:
			push_error("no asteroid art for %s.png" % name)
			return
		_art[name] = texture
	sprite.texture = texture
	sprite.scale = Vector2(scale_px, scale_px)
	sprite.modulate = color
	var pieces: Array = SHAPES.SHAPES.get("asteroid_" + shape, [])
	if pieces.is_empty():
		push_error("no collision piece for asteroid_%s" % shape)
		return
	for v in pieces[0]:
		var point: Vector2 = v * scale_px
		piece.append(point)
		extent = maxf(extent, point.length())
	shape_node.polygon = piece
	# volume, not area: the same shove that sends a pebble flying only leans a hill
	mass = clampf(pow(extent / MASS_REACH, 3.0) * MASS_UNIT, MASS_MIN, MASS_MAX)


## How far the stone reaches along a world direction - what a caller outside it
## needs in order to measure its own clearance.
func reach_toward(dir: Vector2) -> float:
	var local := dir.rotated(-global_rotation)
	var best := 0.0
	for v in piece:
		best = maxf(best, v.dot(local))
	return best
