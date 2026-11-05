extends SceneTree

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _ship: RigidBody2D
var _root: Node2D


func _initialize() -> void:
	call_deferred("_run")


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	await _steps(4)
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", "04")
	rock.set("px_scale", 2.0)
	_root.add_child(rock)
	rock.global_position = Vector2(1000.0, 270.0)
	print("rock pos=", rock.global_position, " mass=", rock.mass, " freeze=", rock.freeze)
	await _steps(3)
	_ship.global_position = Vector2(660.0, 270.0)
	_ship.linear_velocity = Vector2(517.0, 0.0)
	print("ship hull extents: ")
	for c in _ship.get_children():
		if c is CollisionPolygon2D:
			print("  ", c.name, " disabled=", c.disabled, " poly=", (c as CollisionPolygon2D).polygon.size())
	await _steps(2)
	for i in 30:
		await physics_frame
		print(i, " pos=", _ship.global_position, " v=", _ship.linear_velocity,
			" w=", _ship.angular_velocity, " rot=", _ship.rotation,
			" contacts=", _ship.get_contact_count())
	quit(0)
