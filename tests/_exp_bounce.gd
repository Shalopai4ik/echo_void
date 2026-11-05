extends SceneTree

## Experiment: how the ship's answer to a rock changes with bounce, friction,
## mass and inertia. Not a test - a measuring bench.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _ship: RigidBody2D
var _root: Node2D


func _initialize() -> void:
	call_deferred("_run")


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _material(bounce: float, friction: float) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.bounce = bounce
	m.friction = friction
	return m


func _measure(speed: float, bounce_ship: float, bounce_rock: float,
		friction: float, mass: float, spin: float = 0.0) -> Dictionary:
	for child in _root.get_children():
		if child is RigidBody2D and child != _ship:
			child.queue_free()
	await _steps(3)
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", "04")
	rock.set("px_scale", 2.0)
	_root.add_child(rock)
	rock.global_position = Vector2(1000.0, 270.0)
	rock.linear_velocity = Vector2.ZERO
	rock.angular_velocity = 0.0
	rock.physics_material_override = _material(bounce_rock, friction)
	_ship.physics_material_override = _material(bounce_ship, friction)
	_ship.mass = mass
	_ship.global_position = Vector2(660.0, 270.0)
	_ship.rotation = 0.0
	_ship.linear_velocity = Vector2(speed, 0.0)
	_ship.angular_velocity = spin
	await _steps(2)
	var peak := _ship.linear_velocity.length()
	var min_vx := 999999.0
	var peak_spin := 0.0
	var min_gap := 999999.0
	var contact := -1
	for i in 120:
		await physics_frame
		var v := _ship.linear_velocity
		peak = maxf(peak, v.length())
		min_vx = minf(min_vx, v.x)
		peak_spin = maxf(peak_spin, absf(_ship.angular_velocity))
		var gap := _ship.global_position.distance_to(rock.global_position)
		min_gap = minf(min_gap, gap)
		if contact < 0 and _ship.get_contact_count() > 0:
			contact = i
	return {
		"peak": peak, "min_vx": min_vx, "spin": peak_spin,
		"min_gap": min_gap, "contact": contact,
		"end": _ship.linear_velocity, "pos": _ship.global_position,
	}


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	await _steps(4)
	for bounce in [0.5, 0.25, 0.1, 0.0]:
		var r := await _measure(520.0, bounce, bounce, 0.4, 1.0)
		print("bounce=", bounce, " -> ", r)
	for mass in [1.0, 6.0, 20.0]:
		var r := await _measure(520.0, 0.1, 0.1, 0.4, mass)
		print("mass=", mass, " -> ", r)
	var r2 := await _measure(900.0, 0.1, 0.1, 0.4, 6.0)
	print("fast 900 -> ", r2)
	var r3 := await _measure(120.0, 0.1, 0.1, 0.4, 6.0)
	print("slow 120 -> ", r3)
	quit(0)
