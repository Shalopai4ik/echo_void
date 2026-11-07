extends SceneTree

## Verification: what a meeting with an asteroid costs the ship, and what it does
## to the stone. Run: godot --headless --path . --script tests/collision_response_test.gd
##
## The stones stopped being frozen walls. A rock is a live body now, the hull is
## the heavy one of the pair, and neither side carries restitution - so a ram
## costs the ship speed instead of throwing it back, and the stone leaves with
## whatever momentum its own mass lets it take.
##
## What this suite holds:
##
## 1. the shipped scenes carry the model: masses, masks, materials and the CCD
##    mode that used to eat the momentum of a light stone;
## 2. a pebble: the hull barely notices, the stone leaves;
## 3. a chunk: the hull slows, the stone flies;
## 4. a hill: the stone barely moves and the hull is not thrown backwards;
## 5. a faster meeting is a bigger meeting, and still no reversal;
## 6. an oncoming stone spends more of the hull's speed than a parked one;
## 7. three hits in a row leave a hull that is still flying.
##
## "Thrown back" is the bug this suite exists for: after the fix the forward
## component never goes negative, and the peak speed never rises above what the
## ship arrived with.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

const CRUISE := 520.0
const FAST := 900.0
const SLOW := 200.0
## The hull's own mass, read out of the scene above; named here so a report can
## say what the stone was measured against.
const HULL_MASS := 30.0

var _failed := 0
var _checks := 0
var _root: Node2D


func _initialize() -> void:
	call_deferred("_run")


func _ok(what: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
	print(("PASS  " if ok else "FAIL  ") + what + ("  " + detail if detail != "" else ""))


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


## A rock of the size class the belt actually rolls: shape 16 is a pebble
## (edge 22 px), 05 a chunk (37 px), 01 a hill (76 px).
func _mass_of(shape: String, px_scale: float) -> float:
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", shape)
	rock.set("px_scale", px_scale)
	_root.add_child(rock)
	await _steps(2)
	var mass := rock.mass
	rock.queue_free()
	await _steps(2)
	return mass


## Stage one meeting and measure both sides of it.
##
## The stone sits 420 px in front of the ship and the pair is stepped for two
## seconds. `keep` is the fraction of the approach speed the hull still had on
## the frame the contact was reported, `rock_v` is what the stone was doing six
## frames later, and `moved` is how far the stone had travelled by the end.
func _meet(shape: String, px_scale: float, speed: float, stone_speed: float,
		frames: int = 120) -> Dictionary:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	ship.position = Vector2(980.0, 270.0)
	_root.add_child(ship)

	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	rock.set("shape", shape)
	rock.set("px_scale", px_scale)
	# before it enters the tree, which is the only moment its place is ours
	rock.position = Vector2(1400.0, 270.0)
	_root.add_child(rock)
	await _steps(3)

	rock.linear_velocity = Vector2(-stone_speed, 0.0)
	rock.angular_velocity = 0.0
	ship.linear_velocity = Vector2(speed, 0.0)
	ship.angular_velocity = 0.0
	var start := rock.global_position
	var rock_v0 := rock.linear_velocity
	await _steps(2)

	var contact := -1
	var keep := 0.0
	var min_vx := speed
	var peak := speed
	var spin := 0.0
	var rock_v := Vector2.ZERO
	for i in frames:
		await physics_frame
		var v := ship.linear_velocity
		min_vx = minf(min_vx, v.x)
		peak = maxf(peak, v.length())
		spin = maxf(spin, absf(ship.angular_velocity))
		if contact < 0 and ship.get_contact_count() > 0:
			contact = i
			keep = v.length() / maxf(speed, 0.001)
		if contact >= 0 and i == contact + 6:
			rock_v = rock.linear_velocity
	var out := {
		"mass": rock.mass, "v0": speed, "hit": contact >= 0,
		"keep": keep, "min_vx": min_vx, "peak": peak, "spin": spin,
		"rock_v": rock_v.length(), "rock_vx": rock_v.x,
		"rock_gain": (rock_v - rock_v0).length(),
		"moved": start.distance_to(rock.global_position),
		"end": ship.linear_velocity.length(),
	}
	ship.queue_free()
	rock.queue_free()
	await _steps(2)
	return out


func _detail(label: String, r: Dictionary) -> String:
	return "%s: mass %.2f, keep %.2f, min_vx %.0f, spin %.2f, stone %.0f px/s (vx %.0f, gain %.0f), moved %.0f px" % [
		label, r["mass"], r["keep"], r["min_vx"], r["spin"], r["rock_v"], r["rock_vx"], r["rock_gain"], r["moved"]]


## 1. the scenes themselves. A regression here is what brings the rubber ball
## back, so the numbers the whole model rests on are asserted, not assumed.
func _test_configuration() -> void:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	var hull_mat := ship.physics_material_override
	var rock: RigidBody2D = ROCK_SCENE.instantiate()
	var rock_mat := rock.physics_material_override

	_ok("the hull is the heavy body of the pair", ship.mass >= 20.0,
		"ship mass %.1f" % ship.mass)
	_ok("the hull carries no restitution", hull_mat != null and hull_mat.bounce <= 0.05,
		"bounce %.2f" % (hull_mat.bounce if hull_mat != null else -1.0))
	_ok("the stone carries no restitution", rock_mat != null and rock_mat.bounce <= 0.05,
		"bounce %.2f" % (rock_mat.bounce if rock_mat != null else -1.0))
	_ok("the stone is a live body, not a wall", not rock.freeze, "")
	_ok("the pair may exchange impulses both ways",
		(rock.collision_mask & ship.collision_layer) == ship.collision_layer
		and (ship.collision_mask & rock.collision_layer) == rock.collision_layer,
		"ship %d/%d, rock %d/%d" % [ship.collision_layer, ship.collision_mask,
			rock.collision_layer, rock.collision_mask])
	# CCD_MODE_CAST_RAY against a light live body discards most of the momentum
	# of the meeting; measured, that was half the reason the ship felt elastic.
	_ok("the hull does not use the ray CCD mode",
		ship.continuous_cd != RigidBody2D.CCD_MODE_CAST_RAY,
		"mode %d" % ship.continuous_cd)
	ship.queue_free()
	rock.queue_free()
	await _steps(2)

	var pebble := await _mass_of("16", 1.0)
	var chunk := await _mass_of("05", 1.8)
	var hill := await _mass_of("01", 3.2)
	_ok("mass grows with the stone", pebble < chunk and chunk < hill,
		"pebble %.2f < chunk %.2f < hill %.2f" % [pebble, chunk, hill])
	_ok("a hill outweighs a pebble by orders of magnitude", hill > pebble * 100.0,
		"x%.0f" % (hill / maxf(pebble, 0.001)))
	_ok("a pebble is a rounding error next to the hull", pebble < HULL_MASS * 0.05,
		"pebble %.2f vs hull %.0f" % [pebble, HULL_MASS])


## 2. a pebble is a nuisance, not a wall.
func _test_pebble() -> void:
	var r := await _meet("16", 1.0, CRUISE, 0.0)
	_ok("a pebble is hit", r["hit"], _detail("pebble", r))
	_ok("a pebble costs the hull almost nothing", r["keep"] > 0.75,
		_detail("pebble", r))
	_ok("a pebble does not throw the hull back", r["min_vx"] > CRUISE * 0.4,
		_detail("pebble", r))
	_ok("a pebble never speeds the hull up", r["peak"] <= CRUISE * 1.02,
		_detail("pebble", r))
	_ok("the pebble is thrown clear", r["rock_v"] > 120.0 and r["moved"] > 150.0,
		_detail("pebble", r))


## 3. a chunk: a real cost, and the stone goes.
func _test_chunk() -> void:
	var r := await _meet("05", 1.8, CRUISE, 0.0)
	_ok("a chunk is hit", r["hit"], _detail("chunk", r))
	_ok("a chunk takes a share of the hull's speed",
		r["keep"] > 0.6 and r["keep"] < 0.95, _detail("chunk", r))
	_ok("a chunk does not throw the hull back", r["min_vx"] > 0.0,
		_detail("chunk", r))
	_ok("the chunk flies off", r["rock_v"] > 250.0 and r["moved"] > 300.0,
		_detail("chunk", r))
## 4. a hill: the hull pays for it, the stone leans.
func _test_hill() -> void:
	var r := await _meet("01", 3.2, CRUISE, 0.0)
	var stone := await _mass_of("01", 3.2)
	_ok("a hill is hit", r["hit"], _detail("hill", r))
	_ok("a hill outweighs the hull", stone > HULL_MASS,
		"%.1f vs hull %.0f" % [stone, HULL_MASS])
	_ok("a hill takes most of the hull's speed", r["keep"] < 0.8, _detail("hill", r))
	_ok("a hill does not throw the hull back", r["min_vx"] > 0.0, _detail("hill", r))
	_ok("a hill never speeds the hull up", r["peak"] <= CRUISE * 1.02,
		_detail("hill", r))
	_ok("a hill barely moves", r["rock_v"] < 150.0 and r["moved"] < 250.0,
		_detail("hill", r))


## 5. the same stone at three speeds: the faster the meeting, the bigger the
## answer, and still no reversal and no slingshot.
func _test_speed_scaling() -> void:
	var slow := await _meet("01", 3.2, SLOW, 0.0)
	var fast := await _meet("01", 3.2, FAST, 0.0)
	_ok("a fast meeting is still a meeting", fast["hit"], _detail("fast hill", fast))
	_ok("speed is spent, not added", fast["peak"] <= FAST * 1.02,
		_detail("fast hill", fast))
	_ok("no ram, slow or fast, throws the hull back",
		slow["min_vx"] > 0.0 and fast["min_vx"] > 0.0,
		"slow %.0f, fast %.0f" % [slow["min_vx"], fast["min_vx"]])
	_ok("the stone leaves faster from a faster ram", fast["rock_v"] > slow["rock_v"] * 1.5,
		"slow %.0f px/s, fast %.0f px/s" % [slow["rock_v"], fast["rock_v"]])


## 6. a stone coming the other way spends more of the hull's speed than the same
## stone parked, because the solver sees the closing speed and not the ship's
## speed alone.
func _test_oncoming() -> void:
	var parked := await _meet("05", 1.8, CRUISE, 0.0)
	var coming := await _meet("05", 1.8, CRUISE, 220.0)
	_ok("the oncoming stone is hit", coming["hit"], _detail("oncoming chunk", coming))
	_ok("an oncoming stone leaves the hull slower",
		coming["end"] < parked["end"] - 5.0,
		"parked ends %.0f px/s, oncoming ends %.0f px/s" % [parked["end"], coming["end"]])
	_ok("an oncoming stone leaves faster", coming["rock_gain"] > parked["rock_gain"],
		"parked gains %.0f px/s, oncoming gains %.0f px/s" % [
			parked["rock_gain"], coming["rock_gain"]])
	_ok("an oncoming stone does not throw the hull back", coming["min_vx"] > 0.0,
		_detail("oncoming chunk", coming))


## 7. three stones in a row on one hull.
func _test_repeats() -> void:
	var ship: RigidBody2D = SHIP_SCENE.instantiate()
	ship.position = Vector2(0.0, 270.0)
	_root.add_child(ship)
	await _steps(3)

	var hits := 0
	var worst := 1.0
	var min_vx := CRUISE
	for _n in 3:
		ship.linear_velocity = Vector2(CRUISE, 0.0)
		ship.angular_velocity = 0.0
		var rock: RigidBody2D = ROCK_SCENE.instantiate()
		rock.set("shape", "05")
		rock.set("px_scale", 1.8)
		rock.position = ship.global_position + Vector2(340.0, 0.0)
		_root.add_child(rock)
		await _steps(2)
		var contact := -1
		for i in 90:
			await physics_frame
			var v := ship.linear_velocity
			min_vx = minf(min_vx, v.x)
			if contact < 0 and ship.get_contact_count() > 0:
				contact = i
				worst = minf(worst, v.length() / CRUISE)
		if contact >= 0:
			hits += 1
		rock.queue_free()
		await _steps(2)

	_ok("three stones in a row are three hits", hits == 3, "%d of 3" % hits)
	_ok("each hit costs speed but never all of it", worst > 0.45,
		"worst keep %.2f" % worst)
	_ok("a row of hits never throws the hull back", min_vx > 0.0,
		"min_vx %.0f px/s" % min_vx)
	ship.queue_free()
	await _steps(2)


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	await _steps(2)

	await _test_configuration()
	await _test_pebble()
	await _test_chunk()
	await _test_hill()
	await _test_speed_scaling()
	await _test_oncoming()
	await _test_repeats()

	print("%d checks, %d failed" % [_checks, _failed])
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED")
	quit(1 if _failed > 0 else 0)