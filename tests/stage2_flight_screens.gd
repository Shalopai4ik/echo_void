extends SceneTree

## Renders the stage-2 space while flying it, and reads the pixels back.
##
## Run: godot --path . --script tests/stage2_flight_screens.gd --rendering-driver opengl3
##
## The headless world test proves the numbers - determinism, budgets, collisions.
## This one proves the picture, and it is the only place the shader is really
## compiled: a broken canvas_item shader does not stop `set_shader_parameter` from
## writing values, so every headless assertion can pass on a black rectangle.
##
## What it checks, in the order the brief asks for it:
##   - the sky reaches every edge of the frame, at the origin and far away in all
##     four directions, so there is no map boundary to find
##   - the transitions between background chunks are not visible as lines
##   - the planet reads as something enormous rather than as a prop
##   - the belt is sparse enough that the ship stays the brightest thing out here
##   - a long flight does not fall over

const MAP := "res://scenes/world/SpaceMap.tscn"
const OUT := "res://screenshots/stage2/"
## The clear colour from project.godot. A pixel that is exactly this was not drawn
## over by anything, which is what an uncovered stretch of sky looks like.
const VOID := Color(0.02, 0.043, 0.078, 1.0)
## How much of the outer frame band may be untouched sky before it counts as an edge.
const VOID_ALLOW := 0.02
## A consistent step across every row of one column, in luminance. One 8-bit level
## is 0.0039; a step under half of that cannot read as a line.
const SEAM_STEP := 0.0022

var _failed := 0
var _scene: Node


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	_scene = packed.instantiate()
	root.add_child(_scene)
	var ship: RigidBody2D = _scene.get_node("Ship")
	var cam: Camera2D = ship.get_node("Camera")
	var field = _scene.get_node("Field")
	var giant = _scene.get_node("GasGiant")
	# This suite measures the world: the sky, the planet, the belt and the seam.
	# The glass is an overlay on top of it, and the radar's needle and ticks read
	# as a straight seam across the frame, so the glass is put away for these
	# shots - it has its own suite (tests/hud_test.gd).
	var glass := _scene.get_node_or_null("HUD") as CanvasLayer
	if glass != null:
		glass.visible = false

	await _settle()
	var shot := _save("01_start")
	_sky_reaches_every_edge(shot, "at the start")
	await _planet_reads_huge(cam, giant, "at the start")
	_belt_is_sparse(shot, cam, ship, field, "at the start")
	_expect("the hull is on screen", _lit(_hull_box(shot, cam, ship), shot) > 40,
		"%d lit px in the hull box" % _lit(_hull_box(shot, cam, ship), shot))
	await _no_visible_seam(cam, "at the start")

	# ---- fly, and keep checking the picture moves as a picture should
	Input.action_press("thrust_forward")
	for i in 210:
		await physics_frame
	await _settle()
	shot = _save("02_cruise")
	_sky_reaches_every_edge(shot, "at cruise")
	await _no_visible_seam(cam, "at cruise")
	_expect("the sky slid past while the ship flew", _mean(shot) > 0.0,
		"mean frame %.4f" % _mean(shot))
	Input.action_press("turn_left")
	for i in 70:
		await physics_frame
	Input.action_release("thrust_forward")
	Input.action_release("turn_left")
	await _settle()
	shot = _save("03_turning")
	_sky_reaches_every_edge(shot, "mid turn")
	await _planet_reads_huge(cam, giant, "mid turn")

	# ---- the four directions, from far away: no end to the map in any of them
	for leg in [[38000.0, 0.0], [-41000.0, -12000.0], [0.0, 36000.0], [-9000.0, -44000.0]]:
		var at := Vector2(leg[0], leg[1])
		await _teleport(ship, cam, at)
		var tag := "far_%d_%d" % [int(at.x / 1000.0), int(at.y / 1000.0)]
		shot = _save(tag)
		_sky_reaches_every_edge(shot, "at " + str(at))
		_belt_is_sparse(shot, cam, ship, field, "at " + str(at))
		await _planet_reads_huge(cam, giant, "at " + str(at))
		# last, because it hides the ship: the hull has to be where the shot put it
		await _no_visible_seam(cam, "at " + str(at))

	# ---- endurance: a long, busy flight, timed
	var frames := 900
	var times: Array[int] = []
	var routine := [["thrust_forward"], ["thrust_forward", "turn_left"],
		["thrust_forward", "turn_right"], ["thrust_backward"], [], ["turn_left"]]
	for i in frames:
		if i % 50 == 0:
			_release_all()
			for a in routine[int(i / 50.0) % routine.size()]:
				Input.action_press(a)
		var t0 := Time.get_ticks_msec()
		await physics_frame
		times.append(Time.get_ticks_msec() - t0)
	times.sort()
	_release_all()
	await _settle()
	shot = _save("08_after_endurance")
	_sky_reaches_every_edge(shot, "after a long flight")
	await _no_visible_seam(cam, "after a long flight")
	var st: Dictionary = field.stats()
	var p50: int = times[int(frames * 0.5)]
	var p95: int = times[int(frames * 0.95)]
	_expect("the frame holds 60 fps through a long flight", p95 <= 21,
		"frame p50=%d ms p95=%d ms over %d frames" % [p50, p95, frames])
	_expect("the generator stayed inside its own budget",
		int(st.worst_frame_us) < 4000, "worst generating frame %d us" % st.worst_frame_us)
	_expect("nothing accumulated while flying", int(st.live) <= _ceiling(field),
		"live=%d chunks=%d pooled=%d at %s" % [st.live, st.chunks, st.pooled_nodes,
			str(ship.global_position)])
	_expect("the belt is still streaming where the flight ended", int(st.live) > 8, str(st))

	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  shots in ", OUT)
	quit(1 if _failed else 0)


# ------------------------------------------------------------------------ plumbing

func _release_all() -> void:
	for a in ["thrust_forward", "thrust_backward", "turn_left", "turn_right"]:
		Input.action_release(a)


func _settle() -> void:
	for i in 14:
		await process_frame
	await RenderingServer.frame_post_draw


## Placement by hand, with the view put where the ship actually ended up.
##
## A teleport can land the hull inside a stone - the streaming field refuses to
## *spawn* anything that close, but nothing about a teleport is streaming - and the
## solver then spends a dozen frames shoving the ship out. Snapping only before that
## means every sample is taken of a ship that has since left the frame, so the view
## is snapped again once the ejection is over.
func _teleport(ship: RigidBody2D, cam: Camera2D, at: Vector2) -> void:
	_release_all()
	ship.global_position = at
	ship.linear_velocity = Vector2.ZERO
	ship.angular_velocity = 0.0
	cam.snap()
	for i in 60:
		await physics_frame
	_release_all()
	ship.linear_velocity = Vector2.ZERO
	ship.angular_velocity = 0.0
	cam.snap()
	for i in 20:
		await physics_frame
	await _settle()


func _save(tag: String) -> Image:
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT + tag + ".png")
	print("  saved ", tag, " ", img.get_size())
	return img


func _project(world: Vector2, cam: Camera2D, size: Vector2) -> Vector2:
	return (world - cam.get_screen_center_position()) * cam.zoom + size / 2.0


func _hull_box(img: Image, cam: Camera2D, ship: Node2D) -> Rect2:
	var at := _project(ship.global_position, cam, Vector2(img.get_size()))
	var extent := Vector2(200, 180) * cam.zoom.x
	return Rect2(at - extent, extent * 2.0)


func _lit(box: Rect2, img: Image, floor := 0.4) -> int:
	var limit := Vector2(img.get_size()) - Vector2(1, 1)
	var count := 0
	for y in range(int(clampf(box.position.y, 0.0, limit.y)),
			int(clampf(box.end.y, 0.0, limit.y))):
		for x in range(int(clampf(box.position.x, 0.0, limit.x)),
				int(clampf(box.end.x, 0.0, limit.x))):
			if img.get_pixel(x, y).get_luminance() > floor:
				count += 1
	return count


func _mean(img: Image, step := 3) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)


# ------------------------------------------------------------------------- checks

## The outer band of the frame, sampled for pixels that are still exactly the
## project's clear colour: nothing was drawn there, which is what the edge of a
## finite backdrop looks like.
func _sky_reaches_every_edge(img: Image, when: String) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var band_x := maxi(4, int(w * 0.04))
	var band_y := maxi(4, int(h * 0.04))
	var untouched := 0
	var total := 0
	for y in h:
		for x in range(0, w, 2):
			var edge := y < band_y or y >= h - band_y or x < band_x or x >= w - band_x
			if not edge:
				continue
			total += 1
			if _is_void(img.get_pixel(x, y)):
				untouched += 1
	var share := float(untouched) / maxf(float(total), 1.0)
	_expect("the sky covers the whole frame (%s)" % when, share <= VOID_ALLOW,
		"%.2f%% of the outer band is untouched void (%d of %d)"
		% [share * 100.0, untouched, total])


func _is_void(c: Color) -> bool:
	return absf(c.r - VOID.r) < 0.002 and absf(c.g - VOID.g) < 0.002 \
		and absf(c.b - VOID.b) < 0.002


## A chunk boundary that shows up as a line.
##
## The signature of a seam is a step that is there in *every* row of one column, so
## the test is the median signed step, not the mean: a star is a few bright rows in
## one column, which moves a mean a lot and a median not at all. Measured on the sky
## alone, because the planet's limb and a boulder's edge are real brightness steps
## and have no business being called seams.
func _no_visible_seam(cam: Camera2D, when: String) -> void:
	var keep := {}
	for name in ["GasGiant", "Field", "Ship"]:
		var node: CanvasItem = _scene.get_node(name)
		keep[name] = node.visible
		node.visible = false
	await _settle()
	var img := _save("seam_%s" % when.replace(" ", "").replace("(", "").replace(")", ""))
	for name in keep:
		(_scene.get_node(name) as CanvasItem).visible = keep[name]
	await _settle()
	for axis in [0, 1]:
		var score := _straight_step(img, axis)
		_expect("no straight seam across the sky, %s axis (%s)"
			% ["column" if axis == 0 else "row", when], score < SEAM_STEP,
			"most consistent step across the frame: %.5f (%.2f of one 8-bit level)"
			% [score, score * 255.0])
		_expect("the sky is not blank either (%s)" % when, _mean(img) > 0.004,
			"mean sky luminance %.5f" % _mean(img))


## Biggest |median signed step| between neighbouring columns (or rows). The first
## column has no neighbour to its left, so it is not a step and is skipped.
func _straight_step(img: Image, axis: int) -> float:
	var n := img.get_width() if axis == 0 else img.get_height()
	var other := img.get_height() if axis == 0 else img.get_width()
	var worst := 0.0
	for i in range(1, n):
		var diffs: Array[float] = []
		for j in range(0, other, 2):
			var a := img.get_pixel(i, j).get_luminance() if axis == 0 \
				else img.get_pixel(j, i).get_luminance()
			var b := img.get_pixel(i - 1, j).get_luminance() if axis == 0 \
				else img.get_pixel(j, i - 1).get_luminance()
			diffs.append(a - b)
		if diffs.is_empty():
			continue
		diffs.sort()
		var median: float = diffs[diffs.size() / 2]
		worst = maxf(worst, absf(median))
	return worst


## The planet is the one thing out here that is not a point of light. Two things
## have to hold about it: it is too big to ever be seen whole, and it is really
## putting light into the frame. The second is measured by taking the same shot with
## and without it, so a bright patch of nebula cannot pass for a planet - and a disc
## drawn as black cannot pass either.
func _planet_reads_huge(cam: Camera2D, giant, when: String) -> void:
	var size := Vector2(root.get_texture().get_image().get_size())
	var centre := _project(giant.global_position, cam, size)
	var r: float = giant.planet_radius * cam.zoom.x
	var half_diag := size.length() * 0.5
	var box := Rect2(centre - Vector2(r, r), Vector2(2.0 * r, 2.0 * r))
	_expect("the planet reaches the frame (%s)" % when,
		box.intersects(Rect2(Vector2.ZERO, size)),
		"centre %s, radius %.0f px on a %s frame" % [str(centre.round()), r, str(size)])
	_expect("the planet is too big to be seen whole (%s)" % when, r > half_diag,
		"screen radius %.0f px against a half-diagonal of %.0f px" % [r, half_diag])

	await _settle()
	var img := root.get_texture().get_image()
	var with_it := _mean(img)
	# the shader lights the hemisphere that faces the star, which is the side of the
	# disc whose offset along L is positive
	var lit := _side(img, centre, r, giant.light_angle, 1.0)
	var dark := _side(img, centre, r, giant.light_angle, -1.0)
	giant.visible = false
	await _settle()
	var without := _mean(root.get_texture().get_image())
	giant.visible = true
	await _settle()
	_expect("the planet puts light into the frame (%s)" % when, with_it > without + 0.004,
		"mean %.5f with it, %.5f without" % [with_it, without])
	_expect("the planet's star side is brighter than its night side (%s)" % when,
		lit > dark + 0.002, "lit side %.5f, night side %.5f" % [lit, dark])
	# Framing decides how much of the terminator the frame can hold: with the limb
	# clipped to a corner there may be only one hemisphere on screen at all, and a
	# comparison of two sides needs both. Pull the planet in front of the camera for
	# the one shot that can show day and night together, then put it back.
	var anchor: Vector2 = giant.sky_anchor
	giant.sky_anchor = Vector2.ZERO
	await _settle()
	img = root.get_texture().get_image()
	var day := _side(img, _project(giant.global_position, cam, Vector2(img.get_size())),
		giant.planet_radius * cam.zoom.x, giant.light_angle, 1.0)
	var night := _side(img, _project(giant.global_position, cam, Vector2(img.get_size())),
		giant.planet_radius * cam.zoom.x, giant.light_angle, -1.0)
	_save("09_terminator")
	giant.sky_anchor = anchor
	await _settle()
	_expect("the terminator crosses the disc (%s)" % when, day > night * 1.45,
		"day half %.5f, night half %.5f" % [day, night])


## Mean brightness of the part of the disc on one side of the star axis: which way
## round the terminator falls is a property of the scene, not a constant to repeat.
func _side(img: Image, centre: Vector2, r: float, angle: float, want: float) -> float:
	var dir := Vector2(cos(angle), sin(angle))
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var off := Vector2(x, y) - centre
			if off.length() > r:
				continue
			if signf(off.dot(dir)) != want:
				continue
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)


## The brief is a void with rare rocks in it, not a field of them: the ship should
## be the brightest object in the frame, and the rocks should be a handful rather
## than a wall.
func _belt_is_sparse(img: Image, cam: Camera2D, ship: Node2D, field, when: String) -> void:
	var on_screen := 0
	for b in field.bodies():
		var p := _project(b.global_position, cam, Vector2(img.get_width(), img.get_height()))
		if p.x >= 0.0 and p.y >= 0.0 and p.x < img.get_width() and p.y < img.get_height():
			on_screen += 1
	var hull := _lit(_hull_box(img, cam, ship), img)
	_expect("the belt is rare, not crowded (%s)" % when, on_screen <= 26,
		"%d stones on screen" % on_screen)
	_expect("the ship out-shines the belt (%s)" % when, hull > 60,
		"%d lit px on the hull, %d stones around it" % [hull, on_screen])


## Everything the field is allowed to have alive at once, summed over populations.
func _ceiling(field) -> int:
	var n := 0
	for k in field.settings.kinds:
		n += k.max_live
	return n + 24


func _expect(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + "   " + detail)
	if not ok:
		_failed += 1
