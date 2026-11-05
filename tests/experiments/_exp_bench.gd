extends SceneTree

## Clean bench: a fresh ship and a fresh rock for every measurement.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _root: Node2D


func _initialize() -> void:
	call_deferred("_run")


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _mat(bounce: float, friction: float) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.bounce = bounce
	m.friction = friction
	return m


func _measure(speed: float, ship_bounce: float, rock_bounce: float,
		friction: float, mass: float, spin: float = 0.0,
		offset := Vector2.ZERO) -> Dictionary:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	_root.add_child(ship)
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", "04")
	rock.set("px_scale", 2.0)
	_root.add_child(rock)
	await _steps(3)
	ship.physics_material_override = _mat(ship_bounce, friction)
	rock.physics_material_override = _mat(rock_bounce, friction)
	ship.mass = mass
	rock.global_position = Vector2(1200.0, 270.0) + offset
	rock.linear_velocity = Vector2.ZERO
	rock.angular_velocity = 0.0
	ship.global_position = Vector2(700.0, 270.0)
	ship.rotation = 0.0
	ship.linear_velocity = Vector2(speed, 0.0)
	ship.angular_velocity = spin
	await _steps(2)
	var approach := ship.linear_velocity.length()
	var peak := approach
	var min_vx := 999999.0
	var peak_spin := 0.0
	var min_surface := 999999.0
	var contact := -1
	var contact_speed := 0.0
	for i in 140:
		await physics_frame
		var v := ship.linear_velocity
		peak = maxf(peak, v.length())
		min_vx = minf(min_vx, v.x)
		peak_spin = maxf(peak_spin, absf(ship.angular_velocity))
		var to_rock := ship.global_position.direction_to(rock.global_position)
		var gap := ship.global_position.distance_to(rock.global_position)
		min_surface = minf(min_surface, gap - rock.reach_toward(to_rock))
		if contact < 0 and ship.get_contact_count() > 0:
			contact = i
			contact_speed = v.length()
	var out := {
		"approach": approach, "peak": peak, "min_vx": min_vx,
		"spin": peak_spin, "min_surface": min_surface,
		"contact": contact, "contact_speed": contact_speed,
		"end": ship.linear_velocity, "pos": ship.global_position,
	}
	ship.queue_free()
	rock.queue_free()
	await _steps(2)
	return out


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	await _steps(2)
	for bounce in [0.5, 0.2, 0.1, 0.05, 0.0]:
		var r := await _measure(520.0, bounce, bounce, 0.4, 1.0)
		print("bounce=", bounce, " m=1 -> ", r)
	for mass in [1.0, 8.0, 40.0]:
		var r := await _measure(520.0, 0.1, 0.1, 0.4, mass)
		print("bounce=0.1 mass=", mass, " -> ", r)
	var r2 := await _measure(900.0, 0.1, 0.1, 0.4, 40.0)
	print("fast900 m40 -> ", r2)
	var r3 := await _measure(120.0, 0.1, 0.1, 0.4, 40.0)
	print("slow120 m40 -> ", r3)
	quit(0)
