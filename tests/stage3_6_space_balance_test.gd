extends SceneTree

## Sub-stage 3.6 verification: how dense the void actually is, that the sky
## parallaxes correctly and has no seams, that the giant stays one giant, that
## coordinates hold eight million pixels from home, and what the field's own
## frame costs. Run with:
##   godot --headless --path . --script tests/stage3_6_space_balance_test.gd
##
## A. density over two seeds and six places: open space dominates, debris stays
##    rarer than stone, decor does not crowd the frame.
## B. background parallax: a far star shows its own fraction of the travel, the
##    rig rides the camera, a stopped view does not drift on its own.
## C. the tiled sky layers really join edge to edge.
## D. one giant, still in the sky at the zoom the game ships with.
## E. body, chunk and plan agree far from the origin.
## F. the field's whole frame pass stays inside its budget, and its report has no
##    figure that can only ever read zero.
## G. a chunk with nothing to do is not touched: same node, same transform.

const MAP := "res://scenes/world/SpaceMap.tscn"
const BG_DIR := "res://assets/space_bg/"
const BUDGET_MS := 300000
## What one whole `EchoWorldField._physics_process` may spend. The generation
## budget is 2200 us; this is the frame around it, and the number the profile in
## sub-stage 3.6 measured at 460-650 us on this machine, with margin so a slower
## box is not reported as a regression.
const PASS_BUDGET_US := 6000

var _map: Node
var _ship: RigidBody2D
var _cam: Camera2D
var _field: EchoWorldField
var _bg: EchoSpaceBackground
var _giant: GasGiant
var _checks := 0
var _failed := 0
var _started := 0
var _phase := "boot"


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
	_bg = _map.get_node("Background") as EchoSpaceBackground
	_giant = _map.get_node("GasGiant") as GasGiant
	await _wait(90)

	await _test_density()          # A
	await _test_background()       # B
	_test_tiles()                  # C
	await _test_giant()            # D
	await _test_far()              # E
	await _test_pass_cost()        # F
	await _test_quiet_chunks()     # G

	print("TIME  %.1f s, %d checks" % [
		float(Time.get_ticks_msec() - _started) / 1000.0, _checks])
	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _beat(tag: String) -> void:
	_phase = tag
	if Time.get_ticks_msec() - _started > BUDGET_MS:
		print("RESULT: FAILED  watchdog at ", tag)
		quit(3)
	print("-- %s   t=%.0fs  physics=%d" % [tag,
		float(Time.get_ticks_msec() - _started) / 1000.0, Engine.get_physics_frames()])


func _wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _place(at: Vector2, frames: int) -> void:
	_ship.global_position = at
	_ship.linear_velocity = Vector2.ZERO
	_cam.snap()
	await _wait(frames)


## The visible world rectangle, from the camera's own zoom and the viewport size.
func _screen_rect() -> Rect2:
	var size: Vector2 = root.get_visible_rect().size / _cam.zoom
	return Rect2(_cam.global_position - size * 0.5, size)


func _count_named(node: Node, wanted: String) -> int:
	var n := 1 if node.name == String(wanted) else 0
	for child in node.get_children():
		n += _count_named(child, wanted)
	return n


# ------------------------------------------------------------------- A. density

func _test_density() -> void:
	_beat("A. density")
	var points: Array[Vector2] = [
		Vector2.ZERO, Vector2(6000, 0), Vector2(-6000, 3000),
		Vector2(12000, -9000), Vector2(26000, 22000), Vector2(-33000, -27000),
	]
	var rocks := 0
	var debris := 0
	var decor := 0
	var cover := 0.0
	var worst_screen := 0
	var open_screens := 0
	var screens := 0
	for seed_value in [20261102, 777]:
		_field.set_seed(seed_value)
		await _wait(30)
		for at in points:
			await _place(at, 45)
			var rect := _screen_rect()
			var here := 0
			var here_debris := 0
			for body in _field.bodies():
				var p: Vector2 = body.global_position
				if not rect.has_point(p):
					continue
				if String(body.get_meta("object_kind", "")) == "debris":
					here_debris += 1
				else:
					here += 1
				var extent := 40.0
				if body.has_method("world_object_info"):
					extent = float(body.world_object_info().get("extent", 40.0))
				var circle := PI * extent * extent
				var box := Rect2(p - Vector2(extent, extent), Vector2(extent, extent) * 2.0)
				var clipped := box.intersection(rect)
				if clipped.has_area():
					circle *= clipped.get_area() / maxf(box.get_area(), 1.0)
				cover += circle
			# the dim stones stream on a decorative plane, so they are already part of
			# the decor figure: a hull can pass through those, and they count as depth
			var here_decor := _decor_on_screen(rect)
			rocks += here
			debris += here_debris
			decor += here_decor
			worst_screen = maxi(worst_screen, here)
			if here <= 6:
				open_screens += 1
			screens += 1
			print("  seed %d at %s: rocks %d, debris %d, decor %d" % [
				seed_value, str(at), here, here_debris, here_decor])
	var area := maxf(_screen_rect().get_area(), 1.0) * float(screens)
	print("  mean rocks %.1f, debris %.1f, decor %.1f, coverage %.2f%% per screen" % [
		float(rocks) / float(screens), float(debris) / float(screens),
		float(decor) / float(screens), cover / area * 100.0])
	_ok("the void has stones in it", rocks > 0, "%d over %d screens" % [rocks, screens])
	_ok("most screens are open space", open_screens * 4 >= screens * 3,
		"%d of %d have six stones or fewer" % [open_screens, screens])
	_ok("no screen is an asteroid field", worst_screen <= 20,
		"worst screen holds %d" % worst_screen)
	_ok("the stones cover little of the frame", cover / area < 0.08,
		"%.2f%% of the frame" % (cover / area * 100.0))
	_ok("debris stays rarer than stone", float(debris) <= float(rocks) * 0.5,
		"%d debris against %d stones" % [debris, rocks])
	_ok("decor does not crowd the frame", float(decor) / float(screens) <= 12.0,
		"%.1f per screen" % (float(decor) / float(screens)))
	_field.set_seed(20261102)
	await _place(Vector2.ZERO, 30)


func _decor_on_screen(rect: Rect2) -> int:
	var n := 0
	for label in _field.plane_labels():
		var pop = _field.call("_pop_of", label)
		if pop == null or pop.res.physics:
			continue
		for key in pop.chunks:
			for child in (pop.chunks[key] as Node2D).get_children():
				var sp := child as Sprite2D
				if sp != null and rect.has_point(sp.global_position):
					n += 1
	return n


# ---------------------------------------------------------------- B. background

func _test_background() -> void:
	_beat("B. background")
	var band: Node2D = _bg.get_node_or_null("DeepStars")
	_ok("the far star band exists", band != null)
	if band == null:
		return
	_ok("the sky does not turn with the hull",
		not _ship.is_ancestor_of(band) and is_zero_approx(band.global_rotation))
	_ok("the sky rides the camera", _bg.global_position.distance_to(_cam.global_position) < 30.0,
		"%s against %s" % [str(_bg.global_position), str(_cam.global_position)])

	# one star, before and after a thousand pixels of travel
	var sample_cell := Vector2i.ZERO
	var sample: Sprite2D = null
	for cell in band.get("_chunks"):
		var chunk: Node2D = band.get("_chunks")[cell]
		if chunk.get_child_count() > 0:
			sample_cell = cell
			sample = chunk.get_child(0) as Sprite2D
			break
	_ok("the band has a star to watch", sample != null)
	if sample == null:
		return
	var before_world := sample.global_position
	var before_cam := _cam.global_position
	for i in 30:
		_ship.global_position += Vector2(1000, 0) / 30.0
		_cam.snap()
		await physics_frame
	var factor: float = band.get("scroll_factor")
	var travelled := _cam.global_position.x - before_cam.x
	var moved_chunk: Node2D = band.get("_chunks").get(sample_cell)
	var moved := 0.0
	if moved_chunk != null and moved_chunk.get_child_count() > 0:
		moved = (moved_chunk.get_child(0) as Sprite2D).global_position.x - before_world.x
	var screen_delta := moved - travelled
	var expected := -travelled * factor
	_ok("a far star shows its own fraction of the travel",
		absf(screen_delta - expected) < 40.0,
		"screen %.1f against expected %.1f" % [screen_delta, expected])

	# a stopped view must not drift on its own
	var still: String = band.signature()
	await _wait(60)
	_ok("a stopped sky does not drift", band.signature() == still)
	await _place(Vector2.ZERO, 40)


# ------------------------------------------------------------------ C. no seams

func _test_tiles() -> void:
	_beat("C. tiled sky seams")
	var dir := DirAccess.open(BG_DIR)
	_ok("the background folder opens", dir != null)
	if dir == null:
		return
	var checked := 0
	var worst := 0.0
	for f in dir.get_files():
		var lower := f.to_lower()
		if not lower.ends_with(".png") or not lower.contains("tile"):
			continue
		var img := Image.load_from_file(ProjectSettings.globalize_path(BG_DIR + f))
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var horizontal := 0.0
		var vertical := 0.0
		for y in h:
			horizontal += _pixel_gap(img.get_pixel(0, y), img.get_pixel(w - 1, y))
		for x in w:
			vertical += _pixel_gap(img.get_pixel(x, 0), img.get_pixel(x, h - 1))
		horizontal = horizontal / float(maxi(h, 1)) * 255.0
		vertical = vertical / float(maxi(w, 1)) * 255.0
		worst = maxf(worst, maxf(horizontal, vertical))
		checked += 1
	_ok("every tiled layer was checked", checked >= 4, "%d tiles" % checked)
	_ok("a tiled layer joins edge to edge", worst <= 6.0,
		"worst edge gap %.2f/255" % worst)


func _pixel_gap(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) + absf(a.a - b.a)) * 0.25


# ------------------------------------------------------------------ D. the giant

func _test_giant() -> void:
	_beat("D. gas giant")
	_ok("there is exactly one giant in the scene", _count_named(_map, "GasGiant") == 1,
		"%d" % _count_named(_map, "GasGiant"))
	var at_base: Dictionary = _giant.stats()
	var half: Vector2 = root.get_visible_rect().size / _cam.zoom * 0.5
	_ok("the giant reaches the frame at the shipped zoom",
		_giant.covers_screen(_ship.global_position, half),
		"zoom %.2f, centre %s" % [_cam.zoom.x, str(at_base["centre"])])
	_ok("the disc keeps its world radius", is_equal_approx(float(at_base["radius"]), 5200.0))

	# fly three thousand pixels: one planet, still in the sky, still huge
	var before_children := _giant.get_child_count()
	for i in 60:
		_ship.global_position += Vector2(50, 0)
		_cam.snap()
		await physics_frame
	var after: Dictionary = _giant.stats()
	_ok("the giant is not duplicated by chunk transitions",
		_count_named(_map, "GasGiant") == 1 and _giant.get_child_count() == before_children,
		"%d named, %d children" % [_count_named(_map, "GasGiant"), _giant.get_child_count()])
	var away: Vector2 = after["centre"]
	_ok("the giant stays on its leash", away.length() > 5400.0 and away.length() < 6300.0,
		"%.0f px from the hull" % away.length())
	_ok("the giant is drawn behind the world and the hull",
		_giant.z_index < 0
		and _map.get_node("Field").get_index() > _map.get_node("GasGiant").get_index()
		and _ship.get_index() > _map.get_node("Field").get_index())
	await _place(Vector2.ZERO, 40)


# -------------------------------------------------------------- E. far coordinates

func _test_far() -> void:
	_beat("E. coordinates far from home")
	await _place(Vector2(8000000, -8000000), 45)
	var worst := 0.0
	var checked := 0
	for body in _field.bodies():
		var stated: Vector2 = body.get_meta("u", Vector2.ZERO)
		if stated == Vector2.ZERO:
			continue
		var chunk: Node2D = body.get_parent()
		var plane := String(body.get_meta("chunk_id", "")).split(":")[0]
		var pop = _field.call("_pop_of", plane)
		if pop == null:
			continue
		var origin: Vector2 = Vector2(chunk.get_meta("key")) * pop.chunk_px
		worst = maxf(worst, (body.global_position - stated).length())
		worst = maxf(worst, (chunk.global_position - origin).length())
		checked += 1
	_ok("the far window has objects to check", checked > 0, "%d bodies" % checked)
	_ok("body, chunk and plan agree eight million pixels out", worst < 0.05,
		"worst disagreement %.4f px" % worst)
	_ok("coordinates stay finite", _ship.global_position.is_finite()
		and _cam.global_position.is_finite())
	await _place(Vector2.ZERO, 45)


# ---------------------------------------------------------------- F. frame budget

func _test_pass_cost() -> void:
	_beat("F. frame cost")
	_field.reset_report()
	for i in 180:
		_ship.global_position += Vector2(31, -17)
		_cam.snap()
		await physics_frame
	var stats: Dictionary = _field.stats()
	_ok("the field's whole pass stays inside the budget",
		int(stats["worst_pass_us"]) < PASS_BUDGET_US,
		"worst %d us of %d us" % [int(stats["worst_pass_us"]), PASS_BUDGET_US])
	_ok("generation stays inside its own budget", int(stats["worst_frame_us"]) < 6000,
		"%d us" % int(stats["worst_frame_us"]))
	_ok("the live window stays bounded", int(stats["live"]) <= 260 and int(stats["chunks"]) <= 120,
		"%d live in %d chunks" % [int(stats["live"]), int(stats["chunks"])])
	var states: Dictionary = stats["states"]
	_ok("the state report describes every chunk it can have",
		states.has("active") and states.has("generating") and states.has("unloading")
		and states.has("empty"))
	_ok("the state report has no figure that can only read zero", not states.has("unloaded"),
		str(states))


# -------------------------------------------------------------- G. quiet chunks

## A chunk with nothing to do must not be written to: the same node keeps the same
## transform while the ship hovers inside one chunk. Writing it every frame would
## send every frozen body in it back through the physics server.
func _test_quiet_chunks() -> void:
	_beat("G. quiet chunks")
	await _place(Vector2.ZERO, 45)
	var before := {}
	for pop in _field.get("_pops"):
		if not pop.res.physics:
			continue
		for key in pop.chunks:
			var chunk: Node2D = pop.chunks[key]
			before[chunk.get_instance_id()] = chunk.position
	for i in 30:
		await physics_frame
	var moved := 0
	for pop in _field.get("_pops"):
		if not pop.res.physics:
			continue
		for key in pop.chunks:
			var chunk: Node2D = pop.chunks[key]
			if not before.has(chunk.get_instance_id()) \
					or (before[chunk.get_instance_id()] as Vector2) != chunk.position:
				moved += 1
	_ok("a solid chunk at rest is never rewritten", moved == 0,
		"%d chunks of %d moved" % [moved, before.size()])
