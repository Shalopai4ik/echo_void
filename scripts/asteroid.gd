extends RigidBody2D
class_name EchoAsteroid
## One rock. The picture and the collision pieces come out of the same generated
## table, so the shape always sits where the sprite is at whatever scale the
## field asks for. Godot only takes convex polygons on a rigid body, which is
## why a rock carries several of them instead of one outline.
##
## Rocks also carry hit points. Toughness follows mass, damage follows the speed
## the ship closes at, so a pebble gives way to a light touch while a boulder
## wants a boosted ram - see take_hit().

const SHAPES := preload("res://scripts/asteroid_shapes.gd")
const SHAPE_NODES := 6

## How much a rock is worth and how much a ram takes off it.
const HP_BASE := 24.0
const HP_PER_MASS := 26.0
const MAX_MASS := 20.0      ## the heaviest stone the belt rolls
## Damage a ram at the ship's full cruise takes off the rock, in hit points. The
## ship hands over a fraction of its own speed rather than a pixel count, so this
## survives retuning of `max_speed`.
const RAM_FORCE := 182.0
const BOOST_DAMAGE := 1.7   ## extra bite while the ship is burning drive
## Rotational response: a scrape at the contact is what spins a rock, and the
## torque is divided by a solid-disc inertia, so a boulder resists being turned
## twice over - it is heavier and its mass sits further from the centre.
const DISC_INERTIA := 0.5
const SCRAPE := 0.2
const MAX_SPIN := 2.4
## How a rock breaks up.
const FRAG_SCALE := Vector2(0.34, 0.56)
const FRAG_THROW := Vector2(90.0, 240.0)
const FRAG_SPIN := 2.2

enum Hit { GLANCED, CRACKED, SHATTERED }

var kind := ""
var bound := 0.0
var generation := 0
var hit_points := 0.0
var max_hit_points := 0.0

var _pieces: Array[PackedVector2Array] = []
var _tint := Color.WHITE
var _worn := Color.WHITE
var _flash := 0.0
var _spent := false

@onready var sprite: Sprite2D = $Sprite


func _ready() -> void:
	add_to_group("asteroid")


func configure(kind_name: String, texture: Texture2D, px_scale: float,
			   tint: Color, gen: int = 0) -> void:
	kind = kind_name
	generation = gen
	_spent = false
	sprite.texture = texture
	sprite.scale = Vector2(px_scale, px_scale)
	_tint = tint
	_flash = 0.0

	var pieces: Array = SHAPES.SHAPES.get(kind_name, [])
	if pieces.size() > SHAPE_NODES:
		push_warning("%s needs %d collision pieces, the scene has %d"
					 % [kind_name, pieces.size(), SHAPE_NODES])
	var reach := 0.0
	var area := 0.0
	_pieces.clear()
	for i in SHAPE_NODES:
		var node := get_node_or_null("C%d" % i) as CollisionPolygon2D
		if node == null:
			continue
		if i >= pieces.size():
			node.disabled = true
			continue
		var poly := PackedVector2Array()
		for v in pieces[i]:
			var p: Vector2 = v * px_scale
			poly.append(p)
			reach = maxf(reach, p.length())
		_pieces.append(poly)
		area += absf(_signed_area(poly))
		node.polygon = poly
		node.disabled = false
	bound = reach
	# a boulder should shove a pebble aside, not trade momentum with it
	mass = clampf(area / 1200.0, 0.5, MAX_MASS)
	inertia = maxf(DISC_INERTIA * mass * reach * reach, 1.0)
	max_hit_points = HP_BASE + mass * HP_PER_MASS
	hit_points = max_hit_points
	_wear()


## Take a ram. `force` is the closing speed as a fraction of the ship's full
## cruise - 1.0 for a cruise ram, 1.65 for a boosted one - and `boosted` marks
## that the drive was burning, which is what turns a bounce into a breakthrough.
## Returns GLANCED when the ship was already sheering off, so the caller can
## decide what the hit costs it.
func take_hit(force: float, boosted: bool, away: Vector2) -> int:
	if _spent:
		return Hit.GLANCED
	hit_points -= force * RAM_FORCE * (BOOST_DAMAGE if boosted else 1.0)
	if hit_points > 0.0:
		_flash = 1.0
		_wear()
		return Hit.CRACKED
	_spent = true
	# named loosely on purpose: referring to EchoAsteroidField here would close
	# a compile cycle, since the field preloads this scene
	var belt := get_parent()
	if belt != null and belt.has_method("shatter"):
		belt.shatter(self, away)
	else:
		queue_free()
	return Hit.SHATTERED


## Pieces of a rock that just came apart: same art, smaller, thrown outward.
func become_fragment(parent: EchoAsteroid, away: Vector2) -> void:
	configure(parent.kind, parent.sprite.texture,
		parent.sprite.scale.x * randf_range(FRAG_SCALE.x, FRAG_SCALE.y),
		parent._tint, parent.generation + 1)
	var offset := Vector2.RIGHT.rotated(randf() * TAU) * parent.bound * randf_range(0.1, 0.65)
	global_position = parent.global_position + offset
	rotation = randf() * TAU
	linear_velocity = parent.linear_velocity * 0.5 \
		+ away.rotated(randf_range(-0.9, 0.9)) * randf_range(FRAG_THROW.x, FRAG_THROW.y)
	angular_velocity = randf_range(-FRAG_SPIN, FRAG_SPIN)
	_flash = 1.4


func radius() -> float:
	return bound


## The collision pieces in world pixels at the current scale. They are the rock's
## real silhouette, which is exactly what the scanner draws.
func outline() -> Array[PackedVector2Array]:
	return _pieces


## How far the stone actually reaches along `dir` (world direction). The bounding
## circle is many pixels of empty space on an irregular rock, so a ship stopped
## by that would hang in mid air; the support point is where it really touches.
func extent_toward(dir: Vector2) -> float:
	var local := dir.rotated(-rotation)
	var best := 0.0
	for poly in _pieces:
		for v in poly:
			best = maxf(best, v.dot(local))
	return best


## Take the hit. `impulse` is the shove along the contact normal and `scrape` the
## signed tangential slip that spins the rock: the torque goes through the engine,
## so it is divided by the inertia and a boulder resists being turned twice over.
func knock(impulse: Vector2, scrape: float) -> void:
	apply_central_impulse(impulse)
	apply_torque_impulse(scrape * SCRAPE * impulse.length() * bound)
	_flash = maxf(_flash, 0.7)


## Read and written a frame later than the impulse, because the engine has not
## folded a torque into the body yet when knock() returns - clamping in place
## would read the stale zero and wipe the impulse it just queued.
func _physics_process(_delta: float) -> void:
	if absf(angular_velocity) > MAX_SPIN:
		angular_velocity = clampf(angular_velocity, -MAX_SPIN, MAX_SPIN)


func _process(delta: float) -> void:
	if _flash <= 0.0:
		return
	_flash = maxf(_flash - delta * 3.2, 0.0)
	sprite.modulate = _worn.lerp(Color(0.86, 0.95, 1.0), clampf(_flash, 0.0, 1.0))


## A damaged stone loses colour before it loses shape.
func _wear() -> void:
	var used := 1.0 - clampf(hit_points / max_hit_points, 0.0, 1.0)
	_worn = _tint.lerp(Color(0.74, 0.43, 0.36), used * 0.55)
	sprite.modulate = _worn


func _signed_area(poly: PackedVector2Array) -> float:
	var sum := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		sum += a.x * b.y - b.x * a.y
	return sum * 0.5
