extends SceneTree

## Experiment: what the ship and a rock do to each other with the scenes as they
## are shipped. Every trial builds its own ship, so one hit cannot contaminate
## the next one; the rock is placed before it enters the tree, which is the only
## moment its position is unambiguously ours.
##
## Reports, per trial:
##   m       rock mass as set_form() worked it out
##   keep    fraction of the ship's speed left once the hit is over
##   min_vx  lowest forward component the ship reached (negative = thrown back)
##   spin    worst |angular_velocity| the ship reached
##   rock_v  rock speed 6 frames after contact
##   moved   how far the rock travelled over the rest of the trial
##
## Run: godot --headless --path . --script tests/experiments/_exp_collide2.gd

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _root: Node2D
var _out: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _trial(shape: String, px_scale: float, speed: float, rock_speed: float) -> Dictionary:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	ship.position = Vector2(980.0, 270.0)
	_root.add_child(ship)

	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", shape)
	rock.set("px_scale", px_scale)
	rock.position = Vector2(1400.0, 270.0)
	_root.add_child(rock)
	await _steps(3)

	rock.linear_velocity = Vector2(-rock_speed, 0.0)
	rock.angular_velocity = 0.0
	ship.linear_velocity = Vector2(speed, 0.0)
	ship.angular_velocity = 0.0
	var start := rock.global_position
	await _steps(2)

	var min_vx := 999999.0
	var peak_spin := 0.0
	var contact := -1
	var rock_v := Vector2.ZERO
	var stay := Vector2.ZERO
	for i in 120:
		await physics_frame
		var v := ship.linear_velocity
		min_vx = minf(min_vx, v.x)
		peak_spin = maxf(peak_spin, absf(ship.angular_velocity))
		if contact < 0 and ship.get_contact_count() > 0:
			contact = i
			stay = v
		if contact >= 0 and i == contact + 6:
			rock_v = rock.linear_velocity
	var out := {
		"m": rock.mass, "v0": speed, "contact": contact,
		"min_vx": min_vx, "keep": stay.length() / maxf(speed, 0.001),
		"spin": peak_spin, "rock_v": rock_v.length(),
		"moved": start.distance_to(rock.global_position),
	}
	ship.queue_free()
	rock.queue_free()
	await _steps(2)
	return out


## Several meetings in a row with the same hull. Each pass puts the ship back at
## cruise and drops a fresh stone in front of it, which is what a belt does to a
## pilot who does not steer. What matters here is that the ship is still flying
## after the last one - no flip, no stall, no pile-up.
func _repeat(shape: String, px_scale: float, speed: float, count: int) -> Dictionary:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	ship.position = Vector2(0.0, 270.0)
	_root.add_child(ship)
	await _steps(3)

	var keep_sum := 0.0
	var hits := 0
	var min_vx := 999999.0
	var mass := 0.0
	for _n in count:
		ship.linear_velocity = Vector2(speed, 0.0)
		ship.angular_velocity = 0.0
		var rock: RigidBody2D = ROCK_SCENE.instantiate()
		rock.set("shape", shape)
		rock.set("px_scale", px_scale)
		rock.position = ship.global_position + Vector2(340.0, 0.0)
		_root.add_child(rock)
		await _steps(2)
		mass = rock.mass
		var contact := -1
		for i in 90:
			await physics_frame
			var v := ship.linear_velocity
			min_vx = minf(min_vx, v.x)
			if contact < 0 and ship.get_contact_count() > 0:
				contact = i
				keep_sum += v.length() / maxf(speed, 0.001)
				hits += 1
		rock.queue_free()
		await _steps(2)
	var out := {
		"m": mass, "v0": speed, "contact": hits,
		"min_vx": min_vx, "keep": keep_sum / maxf(float(hits), 1.0),
		"spin": absf(ship.angular_velocity), "rock_v": 0.0, "moved": 0.0,
	}
	ship.queue_free()
	await _steps(2)
	return out


func _report(label: String, r: Dictionary) -> void:
	_out.append("%-24s m=%7.2f v0=%4.0f hit=%3d min_vx=%8.1f keep=%5.2f spin=%5.2f rock_v=%6.1f moved=%6.1f" % [
		label, r["m"], r["v0"], r["contact"], r["min_vx"], r["keep"], r["spin"],
		r["rock_v"], r["moved"]])


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	await _steps(2)

	print("--- shipped scenes ---")
	_report("pebble x1.0 @520", await _trial("16", 1.0, 520.0, 0.0))
	_report("chunk x1.8 @520", await _trial("05", 1.8, 520.0, 0.0))
	_report("hill x3.2 @520", await _trial("01", 3.2, 520.0, 0.0))
	_report("pebble x1.0 @900", await _trial("16", 1.0, 900.0, 0.0))
	_report("hill x3.2 @900", await _trial("01", 3.2, 900.0, 0.0))
	_report("hill x3.2 @200", await _trial("01", 3.2, 200.0, 0.0))
	_report("chunk x2.4 @520", await _trial("05", 2.4, 520.0, 0.0))
	_report("hill x4.2 @520", await _trial("01", 4.2, 520.0, 0.0))
	_report("chunk vs oncoming 220", await _trial("05", 1.8, 520.0, 220.0))
	_report("hill vs oncoming 220", await _trial("01", 3.2, 520.0, 220.0))
	_report("repeat: 3 pebbles", await _repeat("16", 1.0, 520.0, 3))
	_report("repeat: 3 chunks", await _repeat("05", 1.8, 520.0, 3))

	for line in _out:
		print(line)
	quit(0)