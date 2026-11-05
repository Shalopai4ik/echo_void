extends SceneTree

## Headless test for the ship's answer to an asteroid: how hard it is thrown
## back, how much speed it loses, how much it spins, and whether it can still be
## flown afterwards. Every scenario is staged by hand - a parked rock, a parked
## ship, a known velocity - so nothing here depends on the random belt.
##
## Run: godot --headless --path . --script tests/collision_response_test.gd

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _failed := false
var _ship: RigidBody2D
var _root: Node2D


func _initialize() -> void:
	call_deferred("_run")


func _check(what: String, ok: bool, detail: String = "") -> void:
	print(("PASS  " if ok else "FAIL  ") + what + "  " + detail)
	if not ok:
		_failed = true


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


## A rock parked where the test says, with the size the test says.
func _rock(at: Vector2, px_scale: float = 2.0, shape: String = "04") -> RigidBody2D:
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", shape)
	rock.set("px_scale", px_scale)
	_root.add_child(rock)
	rock.global_position = at
	rock.linear_velocity = Vector2.ZERO
	rock.angular_velocity = 0.0
	return rock


## The ship, parked, pointing right, with a known speed.
func _ship_at(at: Vector2, velocity: Vector2, spin: float = 0.0) -> RigidBody2D:
	_ship.global_position = at
	_ship.rotation = 0.0
	_ship.linear_velocity = velocity
	_ship.angular_velocity = spin
	return _ship


## Run one pass at a parked rock and report what the hull did.
## The rock sits to the right, the ship comes from the left.
func _measure(speed: float, distance: float = 320.0,
		px_scale: float = 2.0, spin: float = 0.0,
		offset := Vector2.ZERO, frames: int = 90) -> Dictionary:
	for child in _root.get_children():
		if child is RigidBody2D and child != _ship:
			child.queue_free()
	await _steps(2)
	var rock := _rock(Vector2(0.0, 0.0) + offset, px_scale)
	rock.global_position = Vector2(1000.0, 270.0) + offset
	_ship_at(Vector2(1000.0 - distance, 270.0), Vector2(speed, 0.0), spin)
	await _steps(2)
	var before := _ship.linear_velocity
	var peak := before.length()
	var min_normal := 999999.0
	var max_normal := -999999.0
	var peak_spin := 0.0
	var contact := -1
	for i in frames:
		await physics_frame
		var v := _ship.linear_velocity
		peak = maxf(peak, v.length())
		peak_spin = maxf(peak_spin, absf(_ship.angular_velocity))
		# the normal of the contact: the ship meets the rock head on, so it is +X
		var normal := v.x
		min_normal = minf(min_normal, normal)
		max_normal = maxf(max_normal, normal)
		if contact < 0 and _ship.get_contact_count() > 0:
			contact = i
	return {
		"before": before,
		"peak": peak,
		"min_normal": min_normal,
		"max_normal": max_normal,
		"peak_spin": peak_spin,
		"contact": contact,
		"end": _ship.linear_velocity,
		"position": _ship.global_position,
		"rock": rock,
	}


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	await _steps(4)

	# 1. a slow touch
	var slow := await _measure(120.0)
	print("slow: ", slow)
	# 2. a medium hit
	var medium := await _measure(520.0)
	print("medium: ", medium)
	# 3. a fast hit
	var fast := await _measure(900.0)
	print("fast: ", fast)

	print("RESULT: ", "FAILED" if _failed else "ALL PASS")
	quit(1 if _failed else 0)
