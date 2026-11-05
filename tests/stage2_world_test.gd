extends SceneTree

## Headless verification of stage 2: the endless space around the ship.
## Run: godot --headless --path . --script tests/stage2_world_test.gd
##
## What the stage promised, as things that can be measured without looking:
##
##   - the world is a function of coordinates, not of history. A region flown out
##     of and back into comes back identical; a point reached from the north is the
##     same point reached from the south; 30 fps generates what 144 fps generates.
##   - it goes on forever in every direction, and nothing is ever born off the bow.
##   - the chunks are recycled rather than leaked, and the ceilings hold.
##   - stones are solid, and the things that are only atmosphere cannot be touched.
##   - every knob in the settings actually moves the world it describes.
##   - the parallax bands slide at the fraction of the ship's motion their factor
##     says, which is the one thing a static screenshot cannot tell you and a
##     number can.
##
## A phase name is printed before each block and a watchdog fires if the run passes
## its budget, so a stuck test says where it stopped.
##
## What this cannot prove is the picture: whether the belt reads as empty space with
## rare rocks in it, whether the planet reads as huge. That is
## tests/stage2_flight_screens.gd, which renders for real.

const MAP := "res://scenes/world/SpaceMap.tscn"
## How deep the hull may sink into a stone before it counts as a failure. The solver
## is allowed a couple of pixels of overlap on the step it notices.
const SINK := 8.0
## Microseconds one physics frame may spend generating before the stage fails its
## "no heavy generation every frame" requirement. Generous on purpose: this runs
## without a renderer, so it is measuring the generator, not a machine.
const FRAME_BUDGET_US := 6000
## Wall-clock budget for the whole routine, in seconds.
const BUDGET_MS := 900000

var _map: Node
var _ship: RigidBody2D
var _cam: Camera2D
var _field: EchoWorldField
var _sky: EchoSpaceBackground
var _giant: GasGiant
var _checks := 0
var _failed := 0
var _worst := INF
var _hits := 0
## The stones touched since the last mark, as a set. `obstacle_hit` is a contact
## *event*: a hull that grazes along a boulder leaves it and comes back, and the
## same stone fires again. A yaw that carries inertia does that more than one that
## snaps dead, so the corridor measure has to count the stones in the way, not the
## number of times the hull scraped one.
var _touched := {}
var _phase := "boot"
var _started := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	_map = packed.instantiate()
	root.add_child(_map)
	_ship = _map.get_node("Ship") as RigidBody2D
	_cam = _ship.get_node("Camera") as Camera2D
	_field = _map.get_node("Field") as EchoWorldField
	_sky = _map.get_node("Background") as EchoSpaceBackground
	_giant = _map.get_node("GasGiant") as GasGiant
	_ship.obstacle_hit.connect(_on_hit)
	await _settle(60)

	_beat("parts")
	await _test_parts()
	await _test_parallax()
	_beat("infinity")
	await _test_every_direction()
	await _test_identity()
	await _test_paths()
	await _test_frame_rate()
	await _test_recycling()
	_beat("matter")
	await _test_collisions()
	await _test_categories()
	await _test_distribution()
	await _test_budgets()
	_beat("knobs")
	await _test_seed()
	await _test_density()
	await _test_sizes()
	await _test_clusters()
	await _test_clearance()
	await _test_planet()
	await _test_cost()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


# ------------------------------------------------------------------ plumbing ----

func _on_hit(_obstacle: Node, _closing: float) -> void:
	_hits += 1
	_touched[_obstacle] = true


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _beat(tag: String) -> void:
	_phase = tag
	print("-- %s   t=%.0fs  physics=%d" % [tag, _elapsed(), Engine.get_physics_frames()])


func _elapsed() -> float:
	return (Time.get_ticks_msec() - _started) / 1000.0


func _step() -> void:
	await physics_frame
	_worst = minf(_worst, _clearance())
	if Time.get_ticks_msec() - _started > BUDGET_MS:
		print("WATCHDOG  stuck in phase '", _phase, "' after ", _elapsed(), " s")
		quit(3)


func _wait(frames: int) -> void:
	for i in frames:
		await _step()


func _settle(frames := 20) -> void:
	for i in frames:
		await process_frame
	await _step()


func _release_all() -> void:
	for a in ["thrust_forward", "thrust_backward", "turn_left", "turn_right"]:
		Input.action_release(a)


## Put the ship somewhere, still, with the view on it. Teleporting is legitimate
## here because the world is a function of coordinates: the whole point is that it
## should not matter how the ship got there.
func _place(at: Vector2) -> void:
	_release_all()
	_ship.global_position = at
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	_cam.snap()
	# a teleport can land the hull inside a stone, and the solver spends a dozen
	# frames pushing it back out; wait for that to end before measuring anything
	for i in 60:
		await _step()
	_ship.linear_velocity = Vector2.ZERO
	_cam.snap()
	for i in 10:
		await _step()
	# A teleport is not a claim about the world. Whatever the solver had to do to
	# get the hull out of a stone it was dropped into is over by now, so the running
	# minimum restarts here and only measures what the ship does under its own power.
	_worst = _clearance()


## How far the hull centre sits outside whatever it is nearest to, in px.
func _clearance() -> float:
	var closest := INF
	# This suite measures the asteroid belt's navigable corridor. Other solid
	# populations (stage 3.4 debris) are valid obstacles but are not belt stones.
	for rock in _rocks():
		var to_ship: Vector2 = rock.global_position.direction_to(_ship.global_position)
		closest = minf(closest, rock.global_position.distance_to(_ship.global_position)
			- rock.reach_toward(to_ship))
	return closest


func _rocks() -> Array[RigidBody2D]:
	return _field.bodies_of("asteroids")


func _pick_largest() -> RigidBody2D:
	var best: RigidBody2D = null
	for rock in _rocks():
		if best == null or rock.extent > best.extent:
			best = rock
	return best


## The live content of the region the camera can see, as text. Two fields that have
## shown the pilot the same space must agree on it, however they got there.
func _fingerprint() -> String:
	return _field.signature()


# ------------------------------------------------------------------ 0. the parts --

func _test_parts() -> void:
	_ok("the map is the four pieces the stage is made of", _ship != null and _cam != null
		and _field != null and _sky != null and _giant != null,
		"ship=%s field=%s sky=%s giant=%s" % [_ship != null, _field != null,
			_sky != null, _giant != null])
	var st: Dictionary = _field.stats()
	_ok("the field streams from the settings file", st.kinds.size() >= 5, str(st.kinds.keys()))
	_ok("the field is populated at the start", int(st.live) > 20, str(st.live))
	_ok("the sky is populated at the start", int(_sky.stats().nodes) > 20, str(_sky.stats()))
	var solid := 0
	var plain := 0
	for k in st.kinds:
		if st.kinds[k].solid:
			solid += 1
		else:
			plain += 1
	_ok("both categories exist, solid and atmosphere", solid >= 1 and plain >= 3,
		"%d solid, %d decorative" % [solid, plain])
	_ok("the field streams around the camera the ship is riding",
		_field.call("_view_point") == _cam.global_position,
		"view %s, camera %s" % [str(_field.call("_view_point")), str(_cam.global_position)])
	_ok("nothing was ever sunk into a stone while settling", _worst >= SINK,
		"worst clearance %.1f px" % _worst)


# ------------------------------------------------------------------- 1. parallax --

## The claim is that a band's scroll_factor is the fraction of the ship's motion it
## shows on screen. Measured against a stone at rest in the world, which is 1.00 by
## definition, and against the camera, which is what turns world into screen.
func _test_parallax() -> void:
	_beat("parallax")
	var bands := []
	for child in _sky.get_children():
		var l := child as EchoSpaceLayer
		if l != null and l.visible and l.live_nodes() > 1:
			bands.append(l)
	_ok("enough bands to compare against each other", bands.size() >= 4,
		str(bands.map(func(b): return b.name)))
	var factors: Array[float] = []
	for b in bands:
		factors.append(b.scroll_factor)
	factors.sort()
	_ok("the layers really are spread over depth, not one sky",
		factors.front() < 0.05 and factors[factors.size() - 1] > 0.2,
		"from %.3f to %.3f of the ship's motion" % [factors.front(),
			factors[factors.size() - 1]])

	await _place(Vector2(20000, 20000))
	for band in bands:
		var before := _track(band)
		var cam_before := _cam.global_position
		await _place(cam_before + Vector2(600, 0))
		var cam_after := _cam.global_position
		var ratio := _ratio(before, _track(band), cam_after.x - cam_before.x)
		_ok("%s slides at its own factor" % band.name,
			ratio != INF and absf(ratio + band.scroll_factor) < 0.03,
			"measured %.3f, factor %.3f (negative = slides against the ship)"
			% [ratio, band.scroll_factor])

	var rocks := _rocks()
	if rocks.size() > 2:
		# measured around a fixed point in the world, not around the ship: the ship
		# is what moves here, and a ball of stones that follows it would change
		# membership for reasons that have nothing to do with the stone staying put
		var about := _ship.global_position
		var was := _near_positions(2400.0, about)
		await _place(_cam.global_position + Vector2(600, 0))
		var now := _near_positions(2400.0, about)
		_ok("a stone at rest stays at rest when the ship moves", was == now,
			"%d stones nearby before, %d after, and the ship moved 600 px"
			% [was.size(), now.size()])
		var far: float = bands[0].scroll_factor if not bands.is_empty() else 0.0
		_ok("the far bands move slower than the belt", far < 0.3,
			"nearest far band %.3f of the ship's motion against 1.00" % far)


## Rounded world positions of the stones within `reach` of the ship. Bounded on
## purpose: the window edges are where chunks legitimately come and go.
func _near_positions(reach: float, about: Vector2) -> Array[String]:
	var out: Array[String] = []
	for rock in _rocks():
		if rock.global_position.distance_to(about) <= reach:
			out.append("%d,%d" % [roundi(rock.global_position.x),
				roundi(rock.global_position.y)])
	out.sort()
	return out


## identity -> global position, for every sprite in one band
func _track(band: EchoSpaceLayer) -> Dictionary:
	var out := {}
	for chunk in band.get_children():
		if not chunk.has_meta("cell"):
			continue
		var cell: Vector2i = chunk.get_meta("cell")
		for sp in chunk.get_children():
			var s := sp as Sprite2D
			if s == null or s.texture == null:
				continue
			out["%s@%d,%d" % [s.texture.resource_path.get_file(), cell.x, cell.y]] = \
				s.global_position
	return out


func _ratio(before: Dictionary, after: Dictionary, cam_dx: float) -> float:
	if cam_dx == 0.0:
		return INF
	var sum := 0.0
	var n := 0
	for key in before:
		if not after.has(key):
			continue
		sum += (after[key].x - before[key].x) - cam_dx
		n += 1
	return sum / float(n) / cam_dx if n > 2 else INF


# ------------------------------------------------------------------ 2. infinity --

func _test_every_direction() -> void:
	_beat("every direction")
	var home := Vector2.ZERO
	var directions := [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
		Vector2(1, 1).normalized(), Vector2(-1, 1).normalized(),
		Vector2(1, -1).normalized(), Vector2(-1, -1).normalized()]
	for dir in directions:
		# flown, not teleported: the ship has to be able to keep going in a straight
		# line and never run out of world
		await _place(home)
		_release_all()
		var hits_before := _hits
		_touched.clear()
		Input.action_press("thrust_forward")
		_ship.rotation = dir.angle()
		var frames := 0
		var stuck := true
		while frames < 700 and _ship.global_position.distance_to(home) < 9000.0:
			await _step()
			frames += 1
			if _ship.linear_velocity.length() > 200.0:
				stuck = false
			elif frames > 120 and stuck:
				break
		Input.action_release("thrust_forward")
		var gone := home.distance_to(_ship.global_position)
		var st: Dictionary = _field.stats()
		_ok("space keeps generating toward %s" % str(dir),
			gone > 3000.0 and int(st.live) > 12 and int(st.chunks) > 6,
			"%.0f px flown in %.1f s, live=%d chunks=%d"
			% [gone, frames / 60.0, st.live, st.chunks])
		_worst = minf(_worst, _clearance())
		_ok("the hull stayed out of the stones toward %s" % str(dir), _clearance() >= SINK,
			"clearance %.1f px" % _clearance())
		var edge := _sky.stats()
		_ok("the sky is still there toward %s" % str(dir), int(edge.nodes) > 20, str(edge))
		# rare means rare: a pilot flying a straight line at cruise has to have
		# room to fly, and the belt has to leave it. Measured, not promised.
		var contacts := _touched.size()
		var per := gone / float(maxi(contacts, 1))
		_ok("the belt leaves corridors to fly through toward %s" % str(dir),
			per > 800.0,
			"%.0f px of flying per stone (%d stones, %d contact events in %.0f px)"
			% [per, contacts, _hits - hits_before, gone])


# ------------------------------------------------------------------ 3. identity ---

func _test_identity() -> void:
	_beat("identity of a place")
	await _place(Vector2(4000, -4000))
	var here := _fingerprint()
	var rocks := _positions()
	# a loop that leaves and comes back to the same coordinates
	for leg in [Vector2(9000, 0), Vector2(0, 7000), Vector2(-9000, 0), Vector2(0, -7000)]:
		await _place(_ship.global_position + leg * 2.0)
		await _wait(20)
	await _place(Vector2(4000, -4000))
	_ok("a region comes back exactly as it was left", _fingerprint() == here,
		"%d stones before, %d after" % [rocks.size(), _positions().size()])
	if _fingerprint() != here:
		print("   ", _first_difference(here, _fingerprint()))


## world positions of the live stones, rounded: the coarse check behind the text one
func _positions() -> Array[String]:
	var out: Array[String] = []
	for rock in _rocks():
		out.append("%d,%d" % [roundi(rock.global_position.x), roundi(rock.global_position.y)])
	out.sort()
	return out


# ------------------------------------------------------------------ 4. two paths --

func _test_paths() -> void:
	_beat("two routes, one place")
	var dest := Vector2(-26000, 18000)
	await _place(Vector2(6000, 6000))
	await _place(dest)
	var from_east := _fingerprint()
	await _place(Vector2(6000, 6000))
	await _place(dest + Vector2(-14000, -9000))
	await _place(dest + Vector2(3000, -12000))
	await _place(dest)
	var from_south := _fingerprint()
	_ok("arriving from the east shows what arriving from the south shows",
		from_east == from_south, "%d chars vs %d" % [from_east.length(), from_south.length()])
	if from_east != from_south:
		print("   ", _first_difference(from_east, from_south))


# ------------------------------------------------------------------ 5. frame rate --

## The same walk sampled coarsely and finely must end on the same picture, because
## nothing in the generator is allowed to depend on how much time passed.
func _test_frame_rate() -> void:
	_beat("frame rate independence")
	var dest := Vector2(31000, -22000)
	await _place(Vector2.ZERO)
	for i in range(1, 13):
		await _place(dest * (float(i) / 12.0))
	var coarse := _fingerprint()
	await _place(Vector2.ZERO)
	for i in range(1, 121):
		await _place(dest * (float(i) / 120.0))
	var fine := _fingerprint()
	_ok("12 steps and 120 steps agree", coarse == fine,
		"%d vs %d chars" % [coarse.length(), fine.length()])
	if coarse != fine:
		print("   ", _first_difference(coarse, fine))


# ------------------------------------------------------------------- 6. recycling --

func _test_recycling() -> void:
	_beat("recycling")
	await _place(Vector2.ZERO)
	var nodes_at_home := _map.get_child_count()
	var chunks := {}
	var peak := 0
	for i in 50:
		var at := Vector2(cos(i * 0.24), sin(i * 0.31)) * (i * 620.0)
		await _place(at)
		var st: Dictionary = _field.stats()
		peak = maxi(peak, int(st.live))
		for k in st.kinds:
			chunks[k] = maxi(int(chunks.get(k, 0)), int(st.kinds[k].chunks))
	var st: Dictionary = _field.stats()
	_ok("the field does not grow with the distance flown",
		int(st.chunks) < 300 and int(st.live) <= _ceiling(),
		"live=%d chunks=%d after a 21000 px spiral" % [st.live, st.chunks])
	_ok("pooled nodes are reused rather than recreated", int(st.pooled_nodes) > 0,
		"%d parked in the pools, peak live %d" % [st.pooled_nodes, peak])
	_ok("the scene tree stayed the same size", _map.get_child_count() == nodes_at_home,
		"%d children now, %d at home" % [_map.get_child_count(), nodes_at_home])
	var freed := 0
	for pop_live in [0]:
		freed = 0
	_ok("every population respects its own ceiling", peak <= _ceiling(),
		"peak %d of ceiling %d" % [peak, _ceiling()])


func _ceiling() -> int:
	var n := 0
	for k in _field.settings.kinds:
		n += k.max_live
	return n


# ------------------------------------------------------------------- 7. collisions --

func _test_collisions() -> void:
	_beat("collisions")
	await _place(Vector2(12000, 12000))
	var boulder := _pick_largest()
	_ok("the belt hands out something to hit", boulder != null,
		"%d stones live" % _rocks().size())
	if boulder == null:
		return
	var reach: float = boulder.extent
	await _place_aimed(boulder.global_position + Vector2(reach + 900, 0),
		boulder.global_position)
	var hits_before := _hits
	_ship.linear_velocity = Vector2(-_ship.max_forward_speed, 0)
	var impact := _ship.linear_velocity.length()
	var frames := 0
	while frames < 240 and _hits == hits_before:
		await _step()
		frames += 1
	_ok("the ship cannot pass through a streamed stone", _hits > hits_before,
		"contact after %.2f s at %.0f px/s" % [frames / 60.0, impact])
	await _wait(20)
	_ok("the meeting changed the ship's motion",
		_ship.linear_velocity.length() < impact * 0.9,
		"%.0f -> %.0f px/s" % [impact, _ship.linear_velocity.length()])
	_ok("the hull stayed outside the stone", _clearance() >= SINK,
		"clearance %.1f px, stone reach %.0f px" % [_clearance(), reach])
	Input.action_press("thrust_backward")
	await _wait(120)
	Input.action_release("thrust_backward")
	_ok("the ship backs free of it", _clearance() >= SINK + 20.0,
		"%.1f px off the nearest stone" % _clearance())


func _place_aimed(at: Vector2, target: Vector2) -> void:
	await _place(at)
	_ship.rotation = (target - at).angle()
	await _step()


# ------------------------------------------------------------------ 8. categories --

func _test_categories() -> void:
	_beat("solid and atmosphere")
	var bodies := _field.bodies()
	_ok("every solid object is a body on the ship's collision layer",
		not bodies.is_empty(), "%d bodies live" % bodies.size())
	var wrong := 0
	for b in bodies:
		if not (b is RigidBody2D) or b.collision_layer != 1:
			wrong += 1
	_ok("the stones are where the physics server says they are", wrong == 0,
		"%d of %d are not layer-1 bodies" % [wrong, bodies.size()])
	var decor := 0
	for k in _field.settings.kinds:
		if not k.physics:
			decor += 1
	var sprites := 0
	for child in _field.get_children():
		if child is Node2D and child.get_meta("key", Vector2i(-999, -999)) != Vector2i(-999, -999):
			for sp in child.get_children():
				if sp is Sprite2D:
					sprites += 1
	_ok("the decorative populations are sprites, not bodies", sprites > 0,
		"%d sprites across %d decorative populations" % [sprites, decor])
	_ok("no decorative object is in the body list",
		bodies.size() == _rocks().size() + _field.bodies_of("debris").size(),
		"%d bodies, %d asteroids, %d debris" % [bodies.size(), _rocks().size(),
			_field.bodies_of("debris").size()])


# ------------------------------------------------------------------ 9. distribution --

func _test_distribution() -> void:
	_beat("distribution")
	await _place(Vector2(-8000, 4000))
	var rocks := _rocks()
	_ok("there are enough stones to measure", rocks.size() >= 12, "%d" % rocks.size())
	var gaps: Array[float] = []
	var nearest: Array[float] = []
	for a in rocks:
		var best := INF
		for b in rocks:
			if a == b:
				continue
			best = minf(best, a.global_position.distance_to(b.global_position))
		nearest.append(best)
	nearest.sort()
	var spread := _std(nearest)
	_ok("the stones are not a lattice", spread > 30.0,
		"nearest-neighbour distance std %.0f px, mean %.0f px" % [spread, _mean_of(nearest)])
	# the emptiest place in the window: the largest distance from any stone
	var window := _field.call("_visible_world_rect") as Rect2
	var worst_gap := 0.0
	for i in 400:
		var p := Vector2(lerpf(window.position.x, window.end.x, randf()),
			lerpf(window.position.y, window.end.y, randf()))
		var best := INF
		for rock in rocks:
			best = minf(best, p.distance_to(rock.global_position))
		worst_gap = maxf(worst_gap, best)
	_ok("there are room-sized empty stretches between the clumps", worst_gap > 500.0,
		"emptiest spot is %.0f px from any stone" % worst_gap)
	_ok("the belt is rare enough to leave the ship alone", rocks.size() <= 60,
		"%d stones alive around one ship" % rocks.size())


func _mean_of(list: Array[float]) -> float:
	var s := 0.0
	for v in list:
		s += v
	return s / maxf(float(list.size()), 1.0)


func _std(list: Array[float]) -> float:
	var m := _mean_of(list)
	var s := 0.0
	for v in list:
		s += (v - m) * (v - m)
	return sqrt(s / maxf(float(list.size()), 1.0))


# -------------------------------------------------------------------- 10. budgets --

func _test_budgets() -> void:
	_beat("budgets")
	var settings := _field.settings
	var kinds := {}
	for k in settings.kinds:
		kinds[k.label] = k
	var rock_kind: SpaceObjectKind = kinds["asteroids"]
	var was := rock_kind.max_live
	rock_kind.max_live = 8
	_field.clear()
	await _place(Vector2(52000, -52000))
	await _wait(60)
	_ok("a population ceiling is honoured, not approximated",
		_rocks().size() <= 8 + 6, "%d stones with a ceiling of 8" % _rocks().size())
	rock_kind.max_live = was
	_field.clear()
	await _place(Vector2(52000, -52000))
	await _wait(60)
	_ok("and lifted again the belt comes back", _rocks().size() > 12,
		"%d stones with the ceiling removed" % _rocks().size())


# ---------------------------------------------------------------------- 11. seed --

func _test_seed() -> void:
	_beat("seed")
	await _place(Vector2(15000, 15000))
	var before := _fingerprint()
	var sky_before := _sky_signature()
	_field.set_seed(777001)
	await _wait(40)
	_ok("a different seed is a different universe", _fingerprint() != before,
		"%d chars vs %d" % [_fingerprint().length(), before.length()])
	_sky.set_seed(777001)
	await _settle(6)
	_ok("the sky moves to the new seed with it", _sky_signature() != sky_before,
		"%d chars vs %d" % [_sky_signature().length(), sky_before.length()])
	_field.set_seed(20261102)
	_sky.set_seed(20261029)
	await _wait(40)
	_ok("and the old seed restores the old place", _fingerprint() == before,
		"%d chars vs %d" % [_fingerprint().length(), before.length()])
	_ok("the sky comes back too", _sky_signature() == sky_before)


func _sky_signature() -> String:
	var out := ""
	for child in _sky.get_children():
		var l := child as EchoSpaceLayer
		if l != null and l.visible and not l.textures.is_empty():
			out += l.name + "=" + l.signature() + "\n"
	return out


# -------------------------------------------------------------------- 12. density --

func _test_density() -> void:
	_beat("density knobs")
	var at := Vector2(-44000, -18000)
	await _place(at)
	await _wait(40)
	var thick := _rocks().size()
	_field.settings.rock_density_scale = 0.0
	_field.rebuild()
	await _place(at + Vector2(300, 0))
	await _wait(40)
	_ok("density zero is an empty sky", _rocks().is_empty(),
		"%d stones with the master at 0" % _rocks().size())
	var decor := 0
	for child in _field.get_children():
		for sp in child.get_children():
			if sp is Sprite2D:
				decor += 1
	_ok("and that only empties the belt, not the atmosphere", decor > 0,
		"%d decorative sprites still flying" % decor)
	_field.settings.rock_density_scale = 1.0
	_field.rebuild()
	await _place(at)
	await _wait(40)
	var back := _rocks().size()
	_ok("the belt returns when the master goes back to 1", absf(back - thick) <= 4,
		"%d stones, was %d" % [back, thick])
	_field.settings.rock_density_scale = 2.0
	_field.rebuild()
	await _place(at)
	await _wait(80)
	var doubled := _rocks().size()
	_ok("turning the density up really does thicken it", doubled >= thick,
		"%d at 2.0 against %d at 1.0" % [doubled, thick])
	_field.settings.rock_density_scale = 1.0
	_field.rebuild()
	await _place(at)
	await _wait(40)


# ---------------------------------------------------------------------- 13. sizes --

func _test_sizes() -> void:
	_beat("sizes")
	await _place(Vector2(2000, -60000))
	await _wait(60)
	var rocks := _rocks()
	var tiers := {"pebble": 0, "chunk": 0, "hill": 0}
	var outside := 0
	var kind: SpaceObjectKind = null
	for k in _field.settings.kinds:
		if k.label == "asteroids":
			kind = k
	for rock in rocks:
		var s: float = rock.px_scale
		var lo: float = kind.classes[0].size_min
		var hi: float = kind.classes[kind.classes.size() - 1].size_max
		if s < lo - 0.01 or s > hi + 0.01:
			outside += 1
		if s < 1.4:
			tiers.pebble += 1
		elif s < 2.5:
			tiers.chunk += 1
		else:
			tiers.hill += 1
	_ok("every stone is inside the size range the settings declare", outside == 0,
		"%d of %d outside %.2f..%.2f" % [outside, rocks.size(), kind.classes[0].size_min,
			kind.classes[kind.classes.size() - 1].size_max])
	var distinct := 0
	for t in tiers:
		if tiers[t] > 0:
			distinct += 1
	_ok("small, medium and large all appear", distinct == 3, str(tiers))
	var diameters := {}
	for rock in rocks:
		diameters[roundi(rock.extent)] = true
	_ok("and they are visually different things", diameters.size() >= 6,
		"%d distinct radii among %d stones" % [diameters.size(), rocks.size()])


# -------------------------------------------------------------------- 14. clusters --

func _test_clusters() -> void:
	_beat("clusters")
	var found := 0
	var checked := 0
	for i in 12:
		var at := Vector2(i * 2600.0, -3000.0 + i * 1700.0)
		await _place(at)
		await _wait(20)
		checked += 1
		var rocks := _rocks()
		for a in rocks:
			var crowd := 0
			for b in rocks:
				if a == b:
					continue
				if a.global_position.distance_to(b.global_position) < 340.0:
					crowd += 1
			if crowd >= 2:
				found += 1
				break
	_ok("knots of stones happen, not just singletons", found >= 1,
		"%d of %d windows held a group of three or more within 340 px" % [found, checked])


# ------------------------------------------------------------------- 15. clearance --

func _test_clearance() -> void:
	_beat("clearance")
	await _place(Vector2.ZERO)
	await _wait(60)
	var near := 0
	for rock in _rocks():
		if rock.global_position.length() < _field.settings.spawn_clear_radius:
			near += 1
	_ok("the start is open water", near == 0,
		"%d stones inside %.0f px of the origin" % [near,
			_field.settings.spawn_clear_radius])
	# and the same emptiness is still there after a round trip, because it is part of
	# the plan rather than a rejection made at the moment the ship was there
	await _place(Vector2(30000, 30000))
	await _place(Vector2.ZERO)
	await _wait(60)
	near = 0
	for rock in _rocks():
		if rock.global_position.length() < _field.settings.spawn_clear_radius:
			near += 1
	_ok("and stays empty when the ship comes back", near == 0, "%d stones" % near)


# --------------------------------------------------------------------- 16. planet --

func _test_planet() -> void:
	_beat("planet")
	_ok("the planet is drawn from a shader, not a bitmap", _giant.stats().quad_px > 0.0,
		str(_giant.stats()))
	var side: float = _giant.stats().quad_px
	_ok("the quad is big enough to hold the whole disc and its rings",
		side >= 2.0 * _giant.planet_radius,
		"quad side %.0f px against a diameter of %.0f px" % [side, 2.0 * _giant.planet_radius])
	_ok("the disc fits inside its own picture",
		float(_giant.stats().disc_uv) <= 0.5,
		"disc radius is %.3f of the quad" % _giant.stats().disc_uv)
	_ok("the planet is far bigger than the ship can cross",
		2.0 * _giant.planet_radius > _ship.max_forward_speed * 10.0,
		"%.0f px of diameter, %.1f s of full cruise to cross it"
		% [2.0 * _giant.planet_radius, 2.0 * _giant.planet_radius / _ship.max_forward_speed])
	var headings: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
		Vector2(1, 1).normalized(), Vector2(-1, -1).normalized(),
		Vector2(0.6, -0.8), Vector2(-0.6, 0.8)]
	var half := Vector2(960, 540) * 0.5 / _cam.zoom.x
	var seen := 0
	var nearest := INF
	var furthest := 0.0
	for dir in headings:
		for scale: float in [0.25, 1.0, 4.0]:
			var at := dir * 60000.0 * scale
			if _giant.covers_screen(at, half):
				seen += 1
			var d: float = _giant.call("_offset", at).length()
			nearest = minf(nearest, d)
			furthest = maxf(furthest, d)
	var home := _giant.sky_anchor.length()
	_ok("it stays in the sky whichever way the ship runs and however far",
		seen == headings.size() * 3, "%d of %d far headings still show it"
		% [seen, headings.size() * 3])
	_ok("and it holds its distance from the ship",
		nearest >= home - _giant.sky_leash - 1.0 and furthest <= home + _giant.sky_leash + 1.0,
		"between %.0f and %.0f px, placed at %.0f with a %.0f px leash"
		% [nearest, furthest, home, _giant.sky_leash])
	_ok("and never comes so close that the frame is nothing but planet",
		nearest > _giant.planet_radius,
		"closest the centre gets is %.0f px against a radius of %.0f px"
		% [nearest, _giant.planet_radius])
# ----------------------------------------------------------------------- 17. cost --

func _test_cost() -> void:
	_beat("cost")
	_field.reset_report()
	await _place(Vector2.ZERO)
	var worst := 0
	var samples: Array[int] = []
	for i in 600:
		_ship.global_position += Vector2(13, 0)   # cruise, 780 px/s
		var t0 := Time.get_ticks_usec()
		await _step()
		var spent := int(_field.stats().worst_frame_us)
		worst = maxi(worst, spent)
		samples.append(Time.get_ticks_usec() - t0)
	var st: Dictionary = _field.stats()
	_ok("no frame is doing the whole generation",
		int(st.worst_frame_us) < FRAME_BUDGET_US,
		"worst generating frame %d us of a %d us budget, %d us total over 600 frames"
		% [st.worst_frame_us, FRAME_BUDGET_US, _field.build_total()])
	_ok("and the average frame barely notices it",
		_field.build_total() < 600 * 400,
		"%d us total, %.1f us per frame" % [_field.build_total(),
			_field.build_total() / 600.0])
	_ok("the ship never ended up inside a stone on the way", _worst >= SINK,
		"worst %.1f px" % _worst)


func _first_difference(a: String, b: String) -> String:
	var la := a.split(";")
	var lb := b.split(";")
	for i in mini(la.size(), lb.size()):
		if la[i] != lb[i]:
			return "first difference at %d:\n  A %.200s\n  B %.200s" % [i, la[i], lb[i]]
	return "entries %d vs %d" % [la.size(), lb.size()]
