extends SceneTree

## Headless test for the asteroid belt: the generated collision table, the
## streaming field, what happens when the ship flies into a rock, and what it
## takes to actually break one.
## Run: godot --headless --path . --script tests/asteroid_test.gd

const SHAPES := preload("res://scripts/asteroid_shapes.gd")
const ROCK_SCENE := preload("res://scenes/Asteroid.tscn")
const ART_DIR := "res://assets/asteroids/"

var _failed := false
var _pristine: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _check(what: String, ok: bool, detail: String = "") -> void:
	print(("PASS  " if ok else "FAIL  ") + what + "  " + detail)
	if not ok:
		_failed = true


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _convex(poly: Array) -> bool:
	var sign := 0
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		var c: Vector2 = poly[(i + 2) % poly.size()]
		var cr := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
		if absf(cr) < 1e-4:
			continue
		if sign == 0:
			sign = 1 if cr > 0.0 else -1
		elif (cr > 0.0) != (sign > 0.0):
			return false
	return true


func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame

	var player: Node2D = scene.get_node("Player")
	var field: EchoAsteroidField = scene.get_node("Asteroids")
	# several phases park the drift to make the belt stand still; keep the real
	# settings so the phase that measures drift can put them back
	_pristine = [field.speed_min, field.speed_max, field.spin_max]

	_test_shapes()
	await _test_field(player, field)
	await _test_impact(player, field)
	await _test_damage(player, field)
	await _test_inertia(field)

	print("RESULT: ", "FAILED" if _failed else "ALL PASS")
	quit(1 if _failed else 0)


## Rocks the test places by hand. They belong to no cell, so the test owns them
## - but only while they are still in the tree: a rock that shattered has already
## been handed back to the field's pool, and freeing it again would corrupt it.
var _placed: Array[EchoAsteroid] = []


func _rock(field: EchoAsteroidField, kind: String, px_scale: float,
		   at: Vector2) -> EchoAsteroid:
	var rock: EchoAsteroid = ROCK_SCENE.instantiate()
	field.add_child(rock)
	rock.configure(kind, load(ART_DIR + kind + ".png"), px_scale, Color.WHITE)
	rock.global_position = at
	rock.linear_velocity = Vector2.ZERO
	rock.angular_velocity = 0.0
	_placed.append(rock)
	return rock


func _sweep(field: EchoAsteroidField) -> void:
	field.enabled = false
	field.clear()
	for rock in _placed:
		if is_instance_valid(rock) and rock.get_parent() == field:
			field.remove_child(rock)
			rock.free()
	_placed.clear()


## Ram a parked rock and report the ship's speed at contact, ten physics frames
## later, and whether the rock gave way.
func _ram(player: Node2D, field: EchoAsteroidField, kind: String,
		  px_scale: float, boosted: bool) -> Dictionary:
	_sweep(field)
	_rock(field, kind, px_scale, Vector2(1000, 270))
	player.position = Vector2(480, 270)
	player.rotation = 0.0
	player.velocity = Vector2.ZERO
	await _steps(2)
	Input.action_press("move_right")
	if boosted:
		Input.action_press("boost")
	var at := 0.0
	var after := 0.0
	var contact := -1
	var broke := false
	for i in 240:
		await physics_frame
		var v: float = player.velocity.length()
		# sampled every frame: a boosted ship grinds up its own debris on the way
		# out, so checking only at the end would miss the shatter entirely
		broke = broke or field.debris_count() > 0
		if contact < 0:
			if player.hull_area.get_overlapping_bodies().size() > 0:
				contact = i
				at = v
		elif i - contact == 10:
			after = v
			break
	Input.action_release("move_right")
	Input.action_release("boost")
	return {"at": at, "after": after, "broke": broke}


func _test_damage(player: Node2D, field: EchoAsteroidField) -> void:
	_sweep(field)
	var small := _rock(field, "asteroid_05", 1.0, Vector2(3000, 3000))
	var big := _rock(field, "asteroid_04", 2.6, Vector2(3600, 3000))
	_check("a bigger rock is a tougher rock",
		big.max_hit_points > small.max_hit_points * 3.0,
		"small=%.0f big=%.0f" % [small.max_hit_points, big.max_hit_points])

	var before := big.hit_points
	var tap := big.take_hit(0.5, false, Vector2.RIGHT)
	_check("a light tap only bruises it",
		tap == EchoAsteroid.Hit.CRACKED and big.hit_points > 0.0 and big.hit_points < before,
		"%.0f -> %.0f" % [before, big.hit_points])
	_check("a bruise makes no debris", field.debris_count() == 0,
		"%d pieces" % field.debris_count())

	var broke := big.take_hit(10.0, true, Vector2.RIGHT)
	_check("a heavy ram shatters it", broke == EchoAsteroid.Hit.SHATTERED, str(broke))
	_check("shattering leaves fragments", field.debris_count() >= 2,
		"%d pieces" % field.debris_count())
	var kid := field.debris_at(0)
	_check("fragments are smaller than their parent",
		kid.sprite.scale.x < big.sprite.scale.x and kid.sprite.scale.x > 0.0,
		"%.2f from %.2f" % [kid.sprite.scale.x, big.sprite.scale.x])
	_check("fragments fly away from the hit",
		kid.linear_velocity.dot(Vector2.RIGHT) > 20.0, str(kid.linear_velocity))
	_check("fragments are one generation down", kid.generation == 1, str(kid.generation))
	_check("the shattered rock left the tree", not _is_in_tree(big), "")

	var pieces := field.debris_count()
	kid.take_hit(10.0, true, Vector2.UP)
	_check("fragments are the last generation", field.debris_count() == pieces - 1,
		"%d -> %d" % [pieces, field.debris_count()])

	# the rule the player actually feels: enough speed and you go through it
	var soft := await _ram(player, field, "asteroid_04", 2.6, false)
	_check("a ram that fails stops the ship",
		soft["at"] > 300.0 and not soft["broke"] and soft["after"] < soft["at"] * 0.5,
		str(soft))
	var hard := await _ram(player, field, "asteroid_05", 1.0, true)
	_check("a ram that breaks keeps the speed",
		hard["broke"] and hard["after"] > hard["at"] * 0.7, str(hard))

	# and the belt itself does not notice: the cell fills back in
	_sweep(field)
	field.enabled = true
	field.speed_min = 0.0
	field.speed_max = 0.0
	field.spin_max = 0.0
	player.position = Vector2(480, 270)
	await _steps(20)
	var count := field.rock_count()
	var victim: EchoAsteroid = field.get_child(0)
	victim.take_hit(10.0, true, Vector2.RIGHT)
	_check("a shattered belt rock frees its cell", field.rock_count() == count - 1,
		"%d -> %d" % [count, field.rock_count()])
	await _steps(30)
	# at least back to where it was: the freed cell is open again, and the gap it
	# left can let a neighbour that was refused before finally land
	_check("the cell fills back in", field.rock_count() >= count,
		"%d rocks, was %d" % [field.rock_count(), count])
	_check("the wreck is still flying nearby", field.debris_count() > 0,
		"%d pieces" % field.debris_count())
	field.enabled = false
	field.clear()


## Size has to reach the physics, not just the picture: the same shove must move
## a pebble far more than a boulder, and the belt must roll big stones slower.
func _test_inertia(field: EchoAsteroidField) -> void:
	_sweep(field)
	var pebble := _rock(field, "asteroid_14", 1.0, Vector2(3000, 3000))
	var boulder := _rock(field, "asteroid_04", 2.6, Vector2(3600, 3000))
	_check("a boulder outweighs a pebble", boulder.mass > pebble.mass * 4.0,
		"%.1f vs %.1f" % [boulder.mass, pebble.mass])
	_check("inertia grows faster than mass",
		boulder.inertia / pebble.inertia > (boulder.mass / pebble.mass) * 3.0,
		"I %.0f vs %.0f" % [boulder.inertia, pebble.inertia])

	var shove := Vector2(900, 0)
	# let the bodies settle first: mass set in the same frame a body enters the
	# space is not yet the mass the server divides an impulse by
	await _steps(2)
	pebble.knock(shove, 1.0)
	boulder.knock(shove, 1.0)
	await _steps(1)
	_check("one shove, one tenth of the spin on a boulder",
		absf(pebble.angular_velocity) > absf(boulder.angular_velocity) * 4.0,
		"%.2f vs %.3f rad/s" % [pebble.angular_velocity, boulder.angular_velocity])
	_check("and the pebble takes the speed",
		pebble.linear_velocity.x > boulder.linear_velocity.x * 4.0,
		"%.0f vs %.0f px/s" % [pebble.linear_velocity.x, boulder.linear_velocity.x])
	await _steps(3)
	_check("nothing cartwheels past the cap",
		absf(pebble.angular_velocity) <= EchoAsteroid.MAX_SPIN + 0.01
		and absf(pebble.angular_velocity) > 1.0,
		"%.2f rad/s" % pebble.angular_velocity)

	# the belt itself: size, drift and spin come off one roll
	_sweep(field)
	# earlier phases park the drift to make the belt stand still; put it back
	field.speed_min = _pristine[0]
	field.speed_max = _pristine[1]
	field.spin_max = _pristine[2]
	field.enabled = true
	field.clear()
	var player := field.get_parent().get_node("Player") as Node2D
	player.position = Vector2(480, 270)
	await _steps(40)
	var sizes: Array[float] = []
	var speeds: Array[float] = []
	var spins: Array[float] = []
	for rock in field.get_children():
		if rock is EchoAsteroid and rock.generation == 0:
			sizes.append(rock.sprite.scale.x)
			speeds.append(rock.linear_velocity.length())
			spins.append(absf(rock.angular_velocity))
	_check("the belt has enough rocks to measure", sizes.size() >= 6, "%d" % sizes.size())
	_check("the roll that makes a stone bigger makes it drift slower",
		_corr(sizes, speeds) < -0.8, "r=%.2f over %d rocks" % [_corr(sizes, speeds), sizes.size()])
	# scraping torques from rock-on-rock contact stir the spin up, so this one is
	# looser than the drift
	_check("and turn slower", _corr(sizes, spins) < -0.6, "r=%.2f" % _corr(sizes, spins))
	field.enabled = false
	field.clear()


func _corr(a: Array, b: Array) -> float:
	var n := mini(a.size(), b.size())
	if n < 3:
		return 0.0
	var ma := 0.0
	var mb := 0.0
	for i in n:
		ma += a[i]
		mb += b[i]
	ma /= n
	mb /= n
	var num := 0.0
	var da := 0.0
	var db := 0.0
	for i in n:
		var x: float = a[i] - ma
		var y: float = b[i] - mb
		num += x * y
		da += x * x
		db += y * y
	if da <= 0.0 or db <= 0.0:
		return 0.0
	return num / sqrt(da * db)


func _is_in_tree(node: Node) -> bool:
	return node != null and is_instance_valid(node) and node.get_parent() != null


# The table the whole feature rests on: convex pieces, inside the picture.
func _test_shapes() -> void:
	var table: Dictionary = SHAPES.SHAPES
	_check("shape table not empty", table.size() >= 10, "%d kinds" % table.size())
	var bad_convex: Array[String] = []
	var bad_bounds: Array[String] = []
	var worst := 0
	for kind: String in table:
		var tex := load(ART_DIR + kind + ".png") as Texture2D
		if tex == null:
			bad_bounds.append(kind + " (no texture)")
			continue
		var img := tex.get_image()
		var half := Vector2(img.get_width(), img.get_height()) * 0.5
		var reach := Vector2.ZERO
		var pieces: Array = table[kind]
		worst = maxi(worst, pieces.size())
		for piece: Array in pieces:
			if piece.size() < 3 or not _convex(piece):
				bad_convex.append(kind)
			for v: Vector2 in piece:
				reach = Vector2(maxf(reach.x, absf(v.x)), maxf(reach.y, absf(v.y)))
		# a vertex may sit on the padded edge, never outside the sprite
		if reach.x > half.x + 1.0 or reach.y > half.y + 1.0:
			bad_bounds.append("%s reach=%s half=%s" % [kind, str(reach), str(half)])
	_check("every piece is convex", bad_convex.is_empty(), str(bad_convex))
	_check("pieces stay inside their sprite", bad_bounds.is_empty(), str(bad_bounds))
	_check("scene has room for the worst rock", worst <= 6, "%d pieces" % worst)


func _test_field(player: Node2D, field: EchoAsteroidField) -> void:
	field.speed_min = 0.0
	field.speed_max = 0.0
	field.spin_max = 0.0
	# rocks born before this still carry the drift they were given, and in space
	# nothing damps it out
	field.clear()
	player.position = Vector2(480, 270)
	await _steps(20)
	var count := field.rock_count()
	_check("belt populates", count > 0, "%d rocks" % count)
	_check("belt respects its cap", count <= field.max_rocks, "%d/%d" % [count, field.max_rocks])

	var near := 0
	var closest := 1e9
	for node in field.get_children():
		var rock := node as EchoAsteroid
		if rock == null:
			continue
		var d := rock.global_position.distance_to(player.global_position)
		closest = minf(closest, d - rock.bound)
		if d < field.safe_radius + rock.bound - 1.0:
			near += 1
	_check("nothing spawns on top of the ship", near == 0,
		"%d inside the safe radius, closest surface %.1f of %.1f"
		% [near, closest, field.safe_radius])

	var broken: Array[String] = []
	for node in field.get_children():
		var rock := node as EchoAsteroid
		if rock == null:
			continue
		var want: Array = SHAPES.SHAPES.get(rock.kind, [])
		var live := 0
		for i in 6:
			var c := rock.get_node_or_null("C%d" % i) as CollisionPolygon2D
			if c != null and not c.disabled:
				live += 1
				if c.polygon.size() != want[i].size():
					broken.append("%s C%d" % [rock.kind, i])
		if live != want.size() or rock.bound <= 0.0 or rock.mass <= 0.0:
			broken.append("%s live=%d want=%d" % [rock.kind, live, want.size()])
	_check("collision matches the art", broken.is_empty(), str(broken))

	var first := field.signature()
	player.position = Vector2(90000, -70000)
	await _steps(30)
	_check("belt follows the ship", field.rock_count() > 0, "%d rocks far out" % field.rock_count())
	player.position = Vector2(480, 270)
	await _steps(30)
	_check("the same place is the same belt", first == field.signature(),
		"%d vs %d rocks" % [first.split("|").size(), field.signature().split("|").size()])

	field.set_seed(field.world_seed + 1)
	await _steps(30)
	_check("a new seed is a new belt", first != field.signature(), "")
	field.set_seed(field.world_seed - 1)
	field.enabled = false
	player.position = Vector2(480, 270)
	await _steps(5)
	_check("belt can be switched off", field.rock_count() == 0, "%d rocks" % field.rock_count())


func _test_impact(player: Node2D, field: EchoAsteroidField) -> void:
	_sweep(field)
	# a boulder: tough enough that this ram bruises it instead of ending it
	var rock := _rock(field, "asteroid_04", 2.6, Vector2(900, 270))
	player.rotation = 0.0
	player.velocity = Vector2.ZERO
	player.position = Vector2(480, 270)
	await _steps(3)
	_check("a parked rock stays parked", rock.linear_velocity.length() < 1.0,
		"v=%.2f" % rock.linear_velocity.length())

	# the controller drives the ship, so the test only holds a key down, and it
	# lets go the moment the bounce starts: one pass, one hit
	var parked := rock.global_position
	var full := rock.hit_points
	Input.action_press("move_right")
	var contact := -1
	var speed_at_contact := 0.0
	var slowest := 1e9
	var shoved_back := false
	for i in 160:
		await physics_frame
		var vx: float = player.velocity.x
		if contact < 0:
			if player.hull_area.get_overlapping_bodies().size() > 0:
				contact = i
				speed_at_contact = vx
		else:
			slowest = minf(slowest, absf(vx))
			if i - contact > 6:
				break
		shoved_back = shoved_back or vx < -1.0
	Input.action_release("move_right")

	_check("the ship reached the rock", contact >= 0, "contact on frame %d" % contact)
	_check("the hit cost the ship speed", slowest < speed_at_contact * 0.6,
		"vx at contact=%.0f, lowest just after=%.0f" % [speed_at_contact, slowest])
	_check("the ship bounced back off it", shoved_back, "")
	_check("the rock took the damage", rock.hit_points < full and rock.hit_points > 0.0,
		"%.0f -> %.0f" % [full, rock.hit_points])
	_check("the rock was shoved", rock.linear_velocity.length() > 20.0,
		"v=%.1f, moved %.1f px in six frames"
		% [rock.linear_velocity.length(), rock.global_position.distance_to(parked)])
	var gap := player.global_position.distance_to(rock.global_position)
	var toward: Vector2 = (rock.global_position - player.global_position).normalized()
	var surface: float = rock.extent_toward(-toward)
	_check("the ship is not inside the rock", gap > surface + 20.0,
		"gap=%.1f, rock reaches %.1f toward the ship" % [gap, surface])
	_check("the buffer is tighter than the bounding circle", surface < rock.radius(),
		"support=%.1f bound=%.1f" % [surface, rock.radius()])

	_sweep(field)
	var a := _rock(field, "asteroid_11", 2.0, Vector2(-4000, -4000))
	var b := _rock(field, "asteroid_11", 2.0,
		Vector2(-4000, -4000) + Vector2(a.radius() * 0.8, 0))
	a.linear_velocity = Vector2(90, 0)
	await _steps(40)
	_check("rocks collide with each other", b.linear_velocity.length() > 10.0,
		"b v=%.1f" % b.linear_velocity.length())
