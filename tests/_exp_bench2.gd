extends SceneTree

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
		friction_ship: float, friction_rock: float, inertia: float,
		offset := Vector2.ZERO, spin: float = 0.0) -> Dictionary:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	_root.add_child(ship)
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", "04")
	rock.set("px_scale", 2.0)
	_root.add_child(rock)
	await _steps(3)
	ship.physics_material_override = _mat(ship_bounce, friction_ship)
	rock.physics_material_override = _mat(rock_bounce, friction_rock)
	if inertia > 0.0:
		ship.inertia = inertia
	rock.global_position = Vector2(1200.0, 270.0) + offset
	rock.linear_velocity = Vector2.ZERO
	rock.angular_velocity = 0.0
	ship.global_position = Vector2(700.0, 270.0)
	ship.rotation = 0.0
	ship.linear_velocity = Vector2(speed, 0.0)
	ship.angular_velocity = spin
	await _steps(2)
	var approach := ship.linear_velocity.length()
	var min_vx := 999999.0
	var peak_spin := 0.0
	var contact_speed := 0.0
	var contact := -1
	var after := Vector2.ZERO
	for i in 140:
		await physics_frame
		var v := ship.linear_velocity
		min_vx = minf(min_vx, v.x)
		peak_spin = maxf(peak_spin, absf(ship.angular_velocity))
		if contact < 0 and ship.get_contact_count() > 0:
			contact = i
			contact_speed = v.length()
		if contact >= 0 and i == contact + 12:
			after = v
	var out := {
		"approach": approach, "min_vx": min_vx, "spin": peak_spin,
		"contact": contact, "contact_speed": contact_speed,
		"after12": after, "end": ship.linear_velocity,
		"pos": ship.global_position, "rot": ship.rotation,
	}
	ship.queue_free()
	rock.queue_free()
	await _steps(2)
	return out


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	await _steps(2)
	print("--- how Godot combines bounce ---")
	print("0.1/0.5 ", await _measure(520.0, 0.1, 0.5, 0.4, 0.2, 0.0))
	print("0.1/0.1 ", await _measure(520.0, 0.1, 0.1, 0.4, 0.2, 0.0))
	print("0.5/0.1 ", await _measure(520.0, 0.5, 0.1, 0.4, 0.2, 0.0))
	print("--- inertia ---")
	for inertia in [0.0, 20000.0, 100000.0, 400000.0]:
		print("I=", inertia, " ", await _measure(520.0, 0.1, 0.1, 0.4, 0.2, inertia))
	print("--- friction (grazing hit) ---")
	for fr in [0.05, 0.2, 0.4, 0.8]:
		print("f=", fr, " ", await _measure(520.0, 0.1, 0.1, fr, fr, 100000.0, Vector2(0.0, -40.0)))
	quit(0)
