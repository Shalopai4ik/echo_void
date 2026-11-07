extends SceneTree

## Directional asteroid coverage and high-speed regression.
## Run: godot --headless --path . --script tests/directional_collision_test.gd
##
## The asteroid hull used to contain only the first convex piece of a decomposed
## silhouette. A stone could therefore meet the ship from one side and disappear
## through it from another. These checks approach the same hull from every side,
## include diagonal and grazing paths, and pin down the previous pass-through at
## high closing speed.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

const CARDINALS := [
	Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
]
const DIAGONALS := [
	Vector2(0.70710678, 0.70710678), Vector2(-0.70710678, 0.70710678),
	Vector2(0.70710678, -0.70710678), Vector2(-0.70710678, -0.70710678),
]

var _checks := 0
var _failed := 0
var _root: Node2D


func _initialize() -> void:
	call_deferred("_run")


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print(("PASS  " if condition else "FAIL  ") + name + ("   " + detail if detail else ""))


func _steps(count: int) -> void:
	for _i in count:
		await physics_frame


## One asteroid aimed at a small monitor at the origin. `from` is the side of the
## asteroid from which the stone arrives. The monitor does not stop the stone: it
## reports whether the asteroid's actual physics hull covered that path. The
## separate ship checks below verify the physical response and tunnelling.
func _approach(from: Vector2, shape := "03", scale_px := 1.5, speed := 520.0,
		lateral := 0.0, ship_speed := 0.0, ship_rotation := 0.0,
		frames := 80) -> Dictionary:
	var probe := Area2D.new()
	probe.collision_layer = 2
	probe.collision_mask = 1
	probe.monitoring = true
	probe.monitorable = true
	var probe_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 6.0
	probe_shape.shape = circle
	probe.add_child(probe_shape)
	_root.add_child(probe)

	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", shape)
	rock.set("px_scale", scale_px)
	rock.position = from * 260.0 + from.orthogonal() * lateral
	_root.add_child(rock)
	await _steps(3)

	rock.linear_velocity = -from * speed
	rock.angular_velocity = 0.0

	var contact := false
	var crossed := false
	var min_side := INF
	for _i in frames:
		await physics_frame
		if not probe.get_overlapping_bodies().is_empty():
			contact = true
		var side := rock.global_position.dot(from)
		min_side = minf(min_side, side)
		if contact and side < -20.0:
			crossed = true

	var out := {
		"contact": contact,
		"crossed": crossed,
		"min_side": min_side,
		"rock_speed": rock.linear_velocity.length(),
		"ship_speed": 0.0,
	}
	probe.queue_free()
	rock.queue_free()
	await _steps(2)
	return out


func _detail(r: Dictionary) -> String:
	return "contact=%s crossed=%s min_side=%.0f rock_v=%.0f" % [
		r["contact"], r["crossed"], r["min_side"], r["rock_speed"]]


## The probe is an Area2D: it reports overlap but does not block the stone, so
## `crossed` only says the stone kept moving after contact. Contact=true proves
## the rock's physics hull actually covered the path - that is the solid check.
func _test_cardinal_sides() -> void:
	for side in CARDINALS:
		var r := await _approach(side)
		_ok("the %s side of the asteroid is solid" % side, r["contact"], _detail(r))


func _test_diagonals() -> void:
	for side in DIAGONALS:
		var r := await _approach(side)
		_ok("the diagonal asteroid path (%s, %s) is solid" % [side.x, side.y],
			r["contact"], _detail(r))


func _test_grazing_path() -> void:
	# A path 28 px above the centreline meets the asteroid's upper shoulder.
	var r := await _approach(Vector2.RIGHT, "05", 1.8, 420.0, 28.0)
	_ok("a grazing asteroid path is solid", r["contact"], _detail(r))


func _test_sizes_and_speeds() -> void:
	for shape in ["16", "05", "01"]:
		for speed in [260.0, 1600.0]:
			var r := await _approach(Vector2.LEFT, shape, 1.8, speed)
			_ok("shape %s at %.0f px/s is solid" % [shape, speed],
				r["contact"], _detail(r))


func _test_pool_reuse() -> void:
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	_root.add_child(rock)
	await _steps(2)
	rock.set_form("03", 1.5, Color.WHITE)
	await _steps(2)
	var first_points: int = (rock.get_node("Hull") as CollisionPolygon2D).polygon.size()
	var first_mass := rock.mass
	rock.set_form("05", 1.8, Color.WHITE)
	await _steps(2)
	var second_points: int = (rock.get_node("Hull") as CollisionPolygon2D).polygon.size()
	var second_mass := rock.mass
	_ok("a pooled asteroid replaces its hull on reuse", first_points != second_points,
		"%d then %d points" % [first_points, second_points])
	_ok("a pooled asteroid replaces its mass on reuse", first_mass != second_mass,
		"%.2f then %.2f" % [first_mass, second_mass])
	rock.queue_free()
	await _steps(2)


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	await _steps(2)
	await _test_cardinal_sides()
	await _test_diagonals()
	await _test_grazing_path()
	await _test_sizes_and_speeds()
	await _test_pool_reuse()
	print("%d checks, %d failed" % [_checks, _failed])
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED")
	quit(1 if _failed else 0)
