extends Node2D
class_name EchoAsteroidField
## Endless asteroid belt with real physics.
##
## Same contract as the sky behind it: every rock is a pure function of its
## integer cell and the seed, so the belt looks identical at 30 fps and 144 fps,
## and flying in from the north gives the same universe as flying in from the
## south. A cell is only ever rolled while it is on screen plus `extra_margin`,
## and the rock it produces lives until it drifts back out of that window.
##
## The decorative bands in the background system draw rocks that have no body;
## these do. `Asteroid` nodes are RigidBody2D, so they collide with each other,
## and the ship's hull area reads them through `get_overlapping_bodies()`.
##
## Ramming costs the rock hit points. What falls apart is replaced by fragments
## that belong to no cell: the belt itself stays a pure function of the seed, and
## only the debris left behind by play is transient.

const HASH := preload("res://scripts/space_background/space_hash.gd")
const SHAPES := preload("res://scripts/asteroid_shapes.gd")
const ROCK_SCENE := preload("res://scenes/Asteroid.tscn")
const ART_DIR := "res://assets/asteroids/"

@export_group("Seed")
## Same seed, same belt. Change it to move to another region of space.
@export var world_seed: int = 20261029

@export_group("Generation")
@export var enabled: bool = true
## Chance a cell holds a rock at all.
@export_range(0.0, 1.0, 0.01) var density: float = 0.7
## Nearest and furthest a rock can sit from its cell centre.
@export var min_distance: float = 260.0
@export var max_distance: float = 380.0
## Sprite scale range: the source rocks are 20-80 px.
@export var size_min: float = 1.1
@export var size_max: float = 2.6
@export var speed_min: float = 12.0
@export var speed_max: float = 84.0
@export var spin_max: float = 0.5
## Ceiling on live bodies, and the radius around the ship nothing spawns in.
@export_range(0, 120) var max_rocks: int = 56
@export var safe_radius: float = 250.0
@export var extra_margin: float = 340.0

@export_group("Destruction")
## Ceiling on the fragments left behind by rams. They are transient: they belong
## to no cell, so they never change what the belt looks like.
@export_range(0, 120) var max_debris: int = 56

@export_group("Look")
@export var tint_min: Color = Color(0.76, 0.85, 0.96, 1.0)
@export var tint_max: Color = Color(1.0, 0.98, 0.94, 1.0)

## A rock splits into fragments, its fragments split into smaller ones, and the
## third generation is the last: it just disappears.
const MAX_GENERATION := 1
const FRAGMENTS_MIN := 2
const FRAGMENTS_MAX := 3

var _kinds: Array = []
var _cells := {}
var _live: Array[EchoAsteroid] = []
var _extra: Array[EchoAsteroid] = []
var _pool: Array[EchoAsteroid] = []
var _player: Node2D
var _was_enabled := true

var _cell := Vector2(380, 296)   # recomputed from the distance pair on frame 1
var _jitter := 1.0
var _grid_from := Vector2(-1, -1)


func _ready() -> void:
	add_to_group("asteroid_field")
	var names: Array = SHAPES.SHAPES.keys()
	names.sort()
	for k in names:
		var tex := load(ART_DIR + k + ".png") as Texture2D
		if tex == null:
			push_warning("asteroid field: no texture for " + k)
			continue
		var reach := 0.0
		for piece in SHAPES.SHAPES[k]:
			for v in piece:
				reach = maxf(reach, v.length())
		_kinds.append({"name": k, "tex": tex, "reach": reach})
	if _kinds.is_empty():
		push_warning("asteroid field: nothing in " + ART_DIR)


func set_seed(value: int) -> void:
	if value == world_seed:
		return
	world_seed = value
	clear()


func clear() -> void:
	for rock in _live:
		_release(rock)
	for rock in _extra:
		_release(rock)
	_live.clear()
	_extra.clear()
	_cells.clear()


func rock_count() -> int:
	return _live.size()


func debris_count() -> int:
	return _extra.size()


## The i-th piece of debris still flying around, or null.
func debris_at(i: int) -> EchoAsteroid:
	return _extra[i] if i >= 0 and i < _extra.size() else null


## A rock came apart where it stood. Its cell is freed with it, so the belt keeps
## streaming as if nothing happened, and the pieces are transient extras.
func shatter(rock: EchoAsteroid, away: Vector2) -> void:
	var room := 0
	if rock.generation < MAX_GENERATION:
		room = maxi(max_debris - _extra.size(), 0)
	var wanted := mini(randi_range(FRAGMENTS_MIN, FRAGMENTS_MAX), room)
	var pieces: Array[EchoAsteroid] = []
	for i in wanted:
		pieces.append(_acquire())
	# acquired first: after the retire the wreck is back in the pool, and the
	# pieces must not be able to hand it straight back out again
	_retire(rock)
	for piece in pieces:
		piece.become_fragment(rock, away)
		_extra.append(piece)


## Debug fingerprint: which cell holds which rock and where it came to rest.
## Two belts that covered the same space must agree, however they got there.
func signature() -> String:
	var parts: Array[String] = []
	for rock in _live:
		var cell: Vector2i = rock.get_meta("cell")
		parts.append("%d,%d:%s@%d,%d" % [cell.x, cell.y, rock.kind,
										 roundi(rock.global_position.x),
										 roundi(rock.global_position.y)])
	parts.sort()
	return "|".join(parts)


func _notification(what: int) -> void:
	# parked rocks live outside the tree, so nothing else would free them when
	# the field goes away mid-game
	if what == NOTIFICATION_PREDELETE:
		for rock in _pool:
			if rock != null:
				rock.free()
		_pool.clear()


func _physics_process(_delta: float) -> void:
	if _kinds.is_empty():
		return
	if not enabled:
		# once, on the way out: switching the belt off must not keep wiping the
		# debris of a rock that was broken by hand
		if _was_enabled:
			clear()
		_was_enabled = false
		return
	_was_enabled = true
	_regrid()
	var center := _focus()
	var half := _view_half() + Vector2(extra_margin, extra_margin)
	var window := Rect2(center - half, half * 2)
	var a := (window.position / _cell).floor()
	var b := (window.end / _cell).ceil()
	for cy in range(int(a.y), int(b.y)):
		for cx in range(int(a.x), int(b.x)):
			var cell := Vector2i(cx, cy)
			if _cells.has(cell) or _live.size() >= max_rocks:
				continue
			_try_spawn(cell, center)
	_cull(window)


## Cell size comes from the distance pair the same way the background spawner
## reads it: the cell guarantees the spacing, the jitter only fills it in.
func _regrid() -> void:
	var now := Vector2(min_distance, max_distance)
	if now == _grid_from:
		return
	_grid_from = now
	var span := maxf(max_distance, min_distance + 1.0)
	_cell = Vector2(span, span * 0.78)
	_jitter = clampf((span - min_distance) / span, 0.0, 1.0)


func _try_spawn(cell: Vector2i, center: Vector2) -> void:
	if HASH.hashf(cell.x, cell.y, 5, world_seed) > density:
		return
	var kind: Dictionary = _kinds[HASH.hashi(cell.x, cell.y, 11, world_seed, _kinds.size())]
	var size_roll := HASH.hashf(cell.x, cell.y, 4, world_seed)
	var scale_px := lerpf(size_min, size_max, size_roll)
	var at := (Vector2(cell) + Vector2(_jit(cell, 2), _jit(cell, 3))) * _cell
	var reach: float = kind["reach"] * scale_px
	# the cell spaces the centres, not the stones, so the clear round around the
	# ship has to be grown by the rock's own size, and a rock that would land on
	# a neighbour has to be refused - they shove each other out of that circle
	if at.distance_to(center) < safe_radius + reach or _blocked(at, reach):
		return
	var rock := _acquire()
	var tint: Color = tint_min.lerp(tint_max, HASH.hashf(cell.x, cell.y, 6, world_seed))
	rock.configure(kind["name"], kind["tex"], scale_px, tint)
	rock.global_position = at
	rock.rotation = HASH.hashf(cell.x, cell.y, 7, world_seed) * TAU
	var heading := TAU * HASH.hashf(cell.x, cell.y, 8, world_seed)
	# one roll sets size, drift and spin together and against each other, so big
	# stones crawl and turn slowly while pebbles skitter - momentum, not variety
	var speed := lerpf(speed_max, speed_min, size_roll)
	rock.linear_velocity = Vector2.RIGHT.rotated(heading) * speed
	var spin := lerpf(spin_max, spin_max * 0.25, size_roll)
	rock.angular_velocity = spin if HASH.hashf(cell.x, cell.y, 13, world_seed) > 0.5 else -spin
	rock.set_meta("cell", cell)
	_cells[cell] = rock
	_live.append(rock)


## Snapshot for the HUD radar: where every stone is right now, in world position.
## The radar caches this and only asks again on a scan, so what the pilot flies
## at is the last picture he paid for, not a live feed.
func radar_contacts(center: Vector2, reach: float) -> Array:
	var out: Array = []
	for rock in _live:
		_contact(out, rock, center, reach)
	for rock in _extra:
		_contact(out, rock, center, reach)
	return out


func _contact(out: Array, rock: EchoAsteroid, center: Vector2, reach: float) -> void:
	var d := center.distance_to(rock.global_position)
	if d > reach:
		return
	# the silhouette travels with the contact so the dish can draw the rock at its
	# true proportion instead of a dot that says nothing about size
	out.append({"at": rock.global_position, "rot": rock.rotation, "shape": rock.outline(),
		"hot": rock.bound > 60.0})


func _blocked(at: Vector2, reach: float) -> bool:
	for rock in _live:
		if at.distance_to(rock.global_position) < reach + rock.bound:
			return true
	return false


func _jit(cell: Vector2i, salt: int) -> float:
	return (HASH.hashf(cell.x, cell.y, salt, world_seed) - 0.5) * _jitter


func _cull(window: Rect2) -> void:
	for i in range(_live.size() - 1, -1, -1):
		var rock := _live[i]
		if window.has_point(rock.global_position):
			continue
		_live.remove_at(i)
		_cells.erase(rock.get_meta("cell"))
		_release(rock)
	for i in range(_extra.size() - 1, -1, -1):
		var piece := _extra[i]
		if window.has_point(piece.global_position):
			continue
		_extra.remove_at(i)
		_release(piece)


## Take a rock out of the belt: it stops owning its cell and goes back to the pool.
func _retire(rock: EchoAsteroid) -> void:
	if _live.has(rock):
		_live.erase(rock)
		_cells.erase(rock.get_meta("cell"))
	else:
		_extra.erase(rock)
	_release(rock)


func _acquire() -> EchoAsteroid:
	var rock: EchoAsteroid = _pool.pop_back() if not _pool.is_empty() \
		else ROCK_SCENE.instantiate()
	if rock.get_parent() == null:
		add_child(rock)
	rock.visible = true
	return rock


func _release(rock: EchoAsteroid) -> void:
	rock.visible = false
	if rock.get_parent() != null:
		rock.get_parent().remove_child(rock)
	_pool.append(rock)


func _focus() -> Vector2:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node2D
	return _player.global_position if _player != null else global_position


## Half the visible area in world pixels, camera zoom included. A headless run
## has no real window, so the project's viewport size stands in: without that
## the belt would thin out to nothing on a machine that is only simulating.
func _view_half() -> Vector2:
	var size := Vector2(960, 540)
	var vp := get_viewport()
	if vp == null:
		return size * 0.5
	var rect := vp.get_visible_rect().size
	if rect.x > 1.0 and rect.y > 1.0:
		size = rect
	var cam := vp.get_camera_2d()
	if cam != null:
		return size * 0.5 / cam.zoom
	return size * 0.5
