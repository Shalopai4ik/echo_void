extends SceneTree

## Headless test for what a ram costs the fighter, and for the radar that only
## moves when the scanner is fired.
## Run: godot --headless --path . --script tests/combat_test.gd

const ROCK_SCENE := preload("res://scenes/Asteroid.tscn")
const ART_DIR := "res://assets/asteroids/"

var _failed := false
var _placed: Array[EchoAsteroid] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(what: String, ok: bool, detail: String = "") -> void:
	print(("PASS  " if ok else "FAIL  ") + what + "  " + detail)
	if not ok:
		_failed = true


func _steps(count: int) -> void:
	"""Advance `count` physics frames.

	Anything that reads a value the HUD paints in `_process` must not use this:
	the HUD runs on process frames, and under load the process tick falls behind
	the physics tick, so a bar measured after two physics steps can legitimately
	not have been drawn yet. Use `_frames` for those.
	"""
	for i in count:
		await physics_frame


func _frames(count: int) -> void:
	"""Advance `count` process frames, which is what a drawn value follows."""
	for i in count:
		await process_frame


func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame

	var ship: Node2D = scene.get_node("Player")
	var field: EchoAsteroidField = scene.get_node("Asteroids")
	var hud: Control = scene.get_node("HUD/Root")
	field.enabled = false
	await _steps(2)

	await _test_bars(ship)
	await _test_drain(ship, hud)
	await _test_ram(ship, field)
	await _test_radar(ship, field, hud)

	print("RESULT: ", "FAILED" if _failed else "ALL PASS")
	quit(1 if _failed else 0)


func _test_bars(ship: Node2D) -> void:
	_check("starts with a full shield and hull",
		ship.shield_ratio() > 0.999 and ship.hull_ratio() > 0.999, "")
	ship.take_damage(40.0)
	_check("the shield soaks the first hit",
		ship.shield_ratio() < 0.65 and ship.hull_ratio() > 0.999,
		"shield=%.2f hull=%.2f" % [ship.shield_ratio(), ship.hull_ratio()])
	ship.take_damage(150.0)
	_check("what the shield cannot hold reaches the hull",
		ship.shield_ratio() < 0.001 and ship.hull_ratio() < 0.9,
		"shield=%.2f hull=%.2f" % [ship.shield_ratio(), ship.hull_ratio()])

	var hull: float = ship.hull_ratio()
	await _steps(int(ship.shield_regen_delay * 60) + 120)
	_check("the shield climbs back after a clean run", ship.shield_ratio() > 0.3,
		"shield=%.2f" % ship.shield_ratio())
	_check("the hull does not", absf(ship.hull_ratio() - hull) < 0.001,
		"hull=%.2f" % ship.hull_ratio())
	await _steps(int(ship.shield_max / ship.shield_regen_rate * 60) + 30)
	_check("the shield stops at full", ship.shield_ratio() > 0.999,
		"shield=%.2f" % ship.shield_ratio())

	ship.take_damage(1000.0)
	_check("an empty hull puts the ship out of action",
		ship.destroyed and ship.hull_ratio() < 0.001, "")
	Input.action_press("move_right")
	await _steps(30)
	var drift: float = ship.velocity.length()
	Input.action_release("move_right")
	_check("a wreck does not answer the controls", drift < 1.0, "v=%.2f" % drift)
	await _steps(int(ship.emergency_restart * 60) + 10)
	_check("the reactor restarts her",
		not ship.destroyed and ship.shield_ratio() > 0.999
		and absf(ship.hull_ratio() - ship.restart_hull) < 0.001,
		"hull=%.2f" % ship.hull_ratio())


## One pass at a parked rock, at cruise: what does it cost the ship?
func _ram_cost(ship: Node2D, field: EchoAsteroidField, kind: String,
			   px_scale: float) -> float:
	for rock in _placed:
		if is_instance_valid(rock) and rock.get_parent() == field:
			field.remove_child(rock)
			rock.free()
	_placed.clear()
	var rock: EchoAsteroid = ROCK_SCENE.instantiate()
	field.add_child(rock)
	rock.configure(kind, load(ART_DIR + kind + ".png"), px_scale, Color.WHITE)
	rock.global_position = Vector2(1100, 270)
	rock.linear_velocity = Vector2.ZERO
	_placed.append(rock)

	ship.shield = ship.shield_max
	ship.hull = ship.hull_max
	ship.destroyed = false
	ship.position = Vector2(480, 270)
	ship.rotation = 0.0
	ship.velocity = Vector2.ZERO
	await _steps(2)
	Input.action_press("move_right")
	var spent := 0.0
	var contact := -1
	for i in 200:
		await physics_frame
		if contact < 0:
			if ship.hull_area.get_overlapping_bodies().size() > 0:
				contact = i
		else:
			spent = maxf(spent, 1.0 - ship.shield_ratio())
			if i - contact > 8:
				break
	Input.action_release("move_right")
	await _steps(5)
	return spent


## The shield bar has to run off the hit, not jump: the glass lags the truth by a
## beat, and the pale tail shows what was lost.
func _test_drain(ship: Node2D, hud: Control) -> void:
	ship.shield = ship.shield_max
	ship.hull = ship.hull_max
	ship.destroyed = false
	# the bar is drawn in _process, so it is read after process frames
	await _frames(2)
	_check("the bar sits settled on the truth while nothing happens",
		absf(hud.shield_display() - ship.shield_ratio()) < 0.02,
		"%.2f vs %.2f" % [hud.shield_display(), ship.shield_ratio()])

	ship.take_damage(60.0)
	var truth: float = ship.shield_ratio()
	var shown: float = hud.shield_display()
	_check("the glass does not jump cut", shown > truth + 0.3,
		"glass %.2f, real %.2f" % [shown, truth])
	_check("the tail covers the loss", hud.shield_ghost() >= shown - 0.001,
		"ghost %.2f, fill %.2f" % [hud.shield_ghost(), shown])

	# process frames, not physics steps: the bar is painted by the HUD's
	# _process, and waiting on the physics tick measures the bar before it has
	# been drawn on a loaded machine
	await _frames(2)
	var mid: float = hud.shield_display()
	_check("it drains instead of snapping", mid < shown and mid > truth,
		"%.2f -> %.2f -> %.2f" % [shown, mid, truth])
	await _steps(90)
	_check("and lands on the truth",
		absf(hud.shield_display() - truth) < 0.01
		and absf(hud.shield_ghost() - hud.shield_display()) < 0.01,
		"glass %.2f, ghost %.2f, real %.2f"
		% [hud.shield_display(), hud.shield_ghost(), truth])
	_check("the tail never drops below the fill",
		hud.shield_ghost() >= hud.shield_display() - 0.001, "")


func _test_ram(ship: Node2D, field: EchoAsteroidField) -> void:
	field.enabled = false
	var pebble: float = await _ram_cost(ship, field, "asteroid_14", 1.0)
	var boulder: float = await _ram_cost(ship, field, "asteroid_04", 2.6)
	_check("a boulder hurts far more than a pebble",
		pebble > 0.0 and boulder > pebble * 3.0,
		"shield lost: pebble %.1f%%, boulder %.1f%%" % [pebble * 100, boulder * 100])
	_check("neither pass is fatal", boulder < 0.6, "boulder took %.0f%%" % (boulder * 100))

	# the reason the coefficients are written against max_speed: moving the whole
	# flight model up or down must not move the balance with it
	ship.max_speed = 2080.0
	ship.acceleration = 7200.0
	var faster := await _ram_cost(ship, field, "asteroid_04", 2.6)
	ship.max_speed = 1040.0
	ship.acceleration = 3600.0
	_check("a cruise ram costs the same whatever cruise is",
		boulder > 0.0 and absf(faster - boulder) < boulder * 0.35,
		"%.1f%% at 1040 px/s, %.1f%% at 2080 px/s" % [boulder * 100, faster * 100])
	# one pass at a boulder leaves the ship hurt but flying
	var tinted: Color = ship.sprite.modulate
	_check("a scratch tints the paint without repainting it",
		tinted.g < 0.995 and tinted.g > 0.9, str(tinted))
	ship.shield = 0.0
	ship.hull = 0.0
	ship.take_damage(1.0)
	# the tint is drawn in _process, so it is read after process frames
	await _frames(2)
	_check("a wreck is tinted harder than a scratch, and still legible",
		ship.sprite.modulate.g < tinted.g and ship.sprite.modulate.g > 0.6,
		"%.2f vs %.2f" % [float(ship.sprite.modulate.g), tinted.g])


func _test_radar(ship: Node2D, field: EchoAsteroidField, hud: Control) -> void:
	for rock in _placed:
		if is_instance_valid(rock):
			rock.queue_free()
	_placed.clear()
	ship.velocity = Vector2.ZERO
	ship.position = Vector2(480, 270)
	field.enabled = true
	field.clear()
	await _steps(40)

	var live := field.rock_count()
	_check("the belt is worth scanning", live >= 4, "%d rocks" % live)
	var all: Array = field.radar_contacts(ship.global_position, 4000.0)
	_check("the radar sees every rock in range", all.size() >= live,
		"%d of %d" % [all.size(), live])
	var tight: Array = field.radar_contacts(ship.global_position, 200.0)
	_check("and nothing past its own edge", tight.is_empty(), "%d at 200px" % tight.size())

	# the scale the reference asks for: a dish about three and a half fighters
	# across, showing the near field at its true proportions
	var ship_len: float = ship.hull_reach.x * 2.0
	var span: float = hud.radar_range / maxf(ship_len, 1.0)
	_check("the dish spans roughly three and a half ship lengths",
		span > 3.0 and span < 4.0, "%.1f ship lengths" % span)
	var near: Array = field.radar_contacts(ship.global_position, hud.radar_range)
	_check("and holds the rocks that are close enough to matter",
		near.size() >= 2 and near.size() <= live, "%d of %d" % [near.size(), live])
	var bare: Array = []
	for contact in near:
		var pieces: Array = contact["shape"]
		if pieces.is_empty():
			bare.append("no silhouette")
		for piece in pieces:
			if (piece as PackedVector2Array).size() < 3:
				bare.append("degenerate piece")
	_check("every contact carries its real outline", bare.is_empty(), str(bare))

	# the glass holds the last sweep, not a live feed
	Input.action_press("scan")
	await process_frame
	Input.action_release("scan")
	await _steps(3)
	var swept: Array = hud.contacts()
	_check("a sweep paints the near field", swept.size() == near.size(),
		"%d blips, %d in range" % [swept.size(), near.size()])

	ship.position = Vector2(90000, 90000)
	ship.velocity = Vector2.ZERO
	await _steps(40)
	var held: Array = hud.contacts()
	_check("flying does not redraw it", held == swept, "%d vs %d" % [held.size(), swept.size()])
	_check("the old picture is now nonsense", _all_far_from(ship, held),
		"%d blips left behind" % held.size())

	Input.action_press("scan")
	await process_frame
	Input.action_release("scan")
	await _steps(3)
	var fresh: Array = hud.contacts()
	_check("a new sweep redraws it from where she is now",
		not fresh.is_empty() and not _all_far_from(ship, fresh),
		"%d fresh blips" % fresh.size())
	field.enabled = false


func _all_far_from(ship: Node2D, contacts: Array) -> bool:
	for contact in contacts:
		if ship.global_position.distance_to(contact["at"]) < 3000.0:
			return false
	return true
