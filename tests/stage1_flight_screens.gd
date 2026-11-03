extends SceneTree

## Renders the stage-1 test map while flying, and reads the pixels back.
## Run: godot --path . --script tests/stage1_flight_screens.gd --rendering-driver opengl3
##
## The headless control test proves the numbers. This one proves the picture: that
## the airframe reads against the sky, that the sky stays behind it rather than
## washing it out, and that the exhaust appears behind the nozzles only while the
## engine is asked for it.
##
## The sample boxes are stated in world pixels and projected, because the window
## this runs in is whatever the OS gives us: at 798 px wide and at 1920 px the same
## fixed screen box counted wildly different numbers for the same ship.

const MAP := "res://scenes/test/TestControlMap.tscn"
const OUT := "res://screenshots/stage1/"
## Around the hull: the airframe is 296 x 200 world px, so this box is a little
## more than it and mostly sky.
const HULL_BOX := Vector2(200, 180)
## Behind the nozzles, where only a lit engine has any business being bright.
const AFT_BOX := Vector2(55, 30)
## Luminance a pixel needs to count as flame rather than void.
## Luminance a pixel needs to count as flame. The void behind a nozzle sits at
## 0.03 and the hull's own highlights at 0.8, so a cold, muted exhaust - which is
## what the art direction asks for - lives in between, around 0.15 to 0.5.
const JET_LUMINANCE := 0.15

## How far aft that box sits: the tail is at -148, the flame reaches -261.
const AFT_REACH := 200.0

## The overlay's own palette, taken from the class that draws it: the test looks
## for these in the captured frame, so it cannot drift away from the picture.
const NOSE_COLOR := ShipDebug.NOSE_COLOR
const MOTION_COLOR := ShipDebug.MOTION_COLOR
const ACCEL_COLOR := ShipDebug.ACCEL_COLOR

## Sampled pixels that make an arrow count as drawn. The overlay's absence measures
## 0 in every window, so this is a floor against noise, not a length claim.
const ARROW_MIN_PX := 12

var _failed := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	var ship: ShipController = scene.get_node("Ship")
	var cam: Camera2D = ship.get_node("Camera")
	await _settle()
	var shot := _save("01_start")
	_airframe_reads(shot, "at rest", cam, ship)
	var parked := _lit(_aft_box(shot, cam, ship), shot)

	Input.action_press("thrust_forward")
	for i in 150:
		await physics_frame
	await _settle()
	shot = _save("02_cruise")
	_airframe_reads(shot, "at cruise", cam, ship)
	var burning := _lit(_aft_box(shot, cam, ship), shot)
	_expect("the exhaust comes out of the tail under thrust",
		burning > parked + 100,
		"%d lit px behind the hull parked, %d under thrust" % [parked, burning])

	Input.action_press("turn_left")
	for i in 45:
		await physics_frame
	Input.action_release("thrust_forward")
	Input.action_release("turn_left")
	await _settle()
	_airframe_reads(_save("03_turning"), "mid turn", cam, ship)

	# coast on: the shot that shows inertia is the one where nothing is pressed
	for i in 240:
		await physics_frame
	await _settle()
	shot = _save("04_gliding_past_rocks")
	_airframe_reads(shot, "coasting", cam, ship)
	var coasted := _lit(_aft_box(shot, cam, ship), shot)
	_expect("the engine cuts when the key is let go", coasted < burning - 100,
		"%d parked, %d cruising, %d coasting" % [parked, burning, coasted])

	# and the two ends of the zoom range, for comparison
	cam.zoom_in(8.0)
	await _wait_idle(90)
	_airframe_reads(_save("05_zoomed_in"), "zoomed in", cam, ship)
	cam.set_view_zoom(cam.min_zoom)
	await _wait_idle(90)
	_airframe_reads(_save("06_zoomed_out"), "zoomed out", cam, ship)

	# an exponential chase owes the moving ship exactly speed / response of lag
	var gap: float = cam.global_position.distance_to(ship.global_position)
	var owed: float = ship.linear_velocity.length() / cam.follow_response
	_expect("camera keeps the ship framed by the lag it promises",
		gap < owed + 12.0, "gap=%.1f px, promised=%.1f px at %.0f px/s"
		% [gap, owed, ship.linear_velocity.length()])

	# ------------------------------------------------------ diagnostics (spec 13)
	# The one picture this stage exists to make: a hull pointing somewhere the
	# velocity is not. The overlay draws three arrows out of the ship, so the
	# check is that they are on the frame at all, and that they land on the sides
	# the model claims - motion to the right, the brake pushing back to the left,
	# the nose parked straight up.
	ship.show_debug = false
	await _broadside(ship, cam)
	await _settle()
	var quiet := _save("07_vectors_off")

	ship.show_debug = true
	await _broadside(ship, cam)
	await _settle()
	var lit := _save("08_vectors_on")
	var size := Vector2(lit.get_size())
	var hull := _project(ship.global_position, cam, size)
	# The longest arrow the overlay draws is 195 world px (a cruise speed at
	# speed_to_px = 0.25), so a 680 px screen window round the hull is the whole
	# drawing, and none of the text panel in the corner.
	var window := Rect2(hull - Vector2(340, 340), Vector2(680, 680))
	var cyan := _tint(lit, NOSE_COLOR, window)
	var gold := _tint(lit, MOTION_COLOR, window)
	var rose := _tint(lit, ACCEL_COLOR, window)
	var cyan_before := _tint(quiet, NOSE_COLOR, window)
	var gold_before := _tint(quiet, MOTION_COLOR, window)
	var rose_before := _tint(quiet, ACCEL_COLOR, window)
	# The bar is twelve sampled pixels, not a fixed count per arrow: the overlay's
	# own absence is 0 px in every one of these windows, and the shortest arrow this
	# pose can produce - the brake at 760 px/s2 through accel_to_px 0.18 and zoom
	# 0.5, a 68 px screen stroke sampled every second pixel - lands in the 25 px
	# band. A bar any higher tests where the arrow happened to fall this run.
	_expect("the nose arrow is on the frame", cyan.n > cyan_before.n + ARROW_MIN_PX,
		"%d cyan px with the overlay, %d without" % [cyan.n, cyan_before.n])
	_expect("the motion arrow is on the frame", gold.n > gold_before.n + ARROW_MIN_PX,
		"%d gold px with the overlay, %d without" % [gold.n, gold_before.n])
	_expect("the acceleration arrow is on the frame",
		rose.n > rose_before.n + ARROW_MIN_PX,
		"%d rose px with the overlay, %d without" % [rose.n, rose_before.n])
	var nose_up: Vector2 = Vector2(cyan.cx, cyan.cy) - hull
	var motion_right: Vector2 = Vector2(gold.cx, gold.cy) - hull
	var brake_left: Vector2 = Vector2(rose.cx, rose.cy) - hull
	_expect("the nose marker points up, where the hull is aimed",
		nose_up.length() > 12.0 and nose_up.y < 0.0 and absf(nose_up.x) < absf(nose_up.y),
		"offset %.0f, %.0f px" % [nose_up.x, nose_up.y])
	_expect("the motion arrow points along the flight path",
		motion_right.length() > 12.0 and motion_right.x > absf(motion_right.y),
		"offset %.0f, %.0f px" % [motion_right.x, motion_right.y])
	_expect("the brake arrow points back along it, not at the tail",
		brake_left.length() > 12.0 and brake_left.x < -absf(brake_left.y),
		"offset %.0f, %.0f px" % [brake_left.x, brake_left.y])
	_expect("the picture shows the hull and the path disagreeing",
		motion_right.x > 0.0 and brake_left.x < 0.0 and nose_up.y < 0.0
		and absf(nose_up.x) < absf(motion_right.x),
		"nose %.0f,%.0f  motion %.0f,%.0f  brake %.0f,%.0f" % [nose_up.x, nose_up.y,
		motion_right.x, motion_right.y, brake_left.x, brake_left.y])
	Input.action_release("thrust_backward")
	ship.show_debug = false
	await _settle()
	var after := _save("09_vectors_off_again")
	var gone := _tint(after, MOTION_COLOR, window)
	_expect("switching the diagnostics off takes the arrows back down",
		gone.n < gold.n * 0.4, "%d gold px with it on, %d after switching off"
		% [gold.n, gone.n])

	# ------------------------------------------- engine jets (sub-stage 1.2)
	# The claim of the whole sub-stage: a lit nozzle is a burning one. Each group is
	# flown from a fixed pose, and the pixels round its own stations are compared
	# between an idle frame and a burning one taken at that same pose - the hull's
	# own brightness cancels out, and what is left is the flame, which is the only
	# thing this layer is allowed to add.
	_ship = ship
	_cam = cam
	# The sky is the noise in a pixel count: a station that gained 200 lit pixels
	# because the hull drifted in front of a different star says nothing about the
	# flame. CanvasItem visibility is inherited, so switching the background off
	# takes the whole nebula out and leaves hull, jets and the dark void.
	var sky := scene.get_node("Background")
	sky.visible = false
	# and out go the stones: a boulder drifting through a 60 px sample window is a
	# bright object appearing and disappearing on its own account, and it would be
	# counted as a jet.
	var field := scene.get_node("Rocks")
	field.visible = false

	await _pose(ship, cam, 0.0)
	await _settle()
	var off_main := _shot(_save("10_jets_idle"), ship, cam)
	Input.action_press("thrust_forward")
	for i in 40:
		await physics_frame
	await _settle()
	var on_main := _shot(_save("11_jets_main"), ship, cam)
	var gain_main := _jet_gain(off_main, on_main, _anchor("MainAft"))
	var gain_vernier := _jet_gain(off_main, on_main, _anchor("StrafeToStarboard"))
	var gain_spin := _jet_gain(off_main, on_main, _anchor("SpinClockwisePort"))
	_expect("the main nozzle burns under W", gain_main > 200,
		"%d lit px gained at the main station" % gain_main)
	_expect("no vernier lights while only the engine is burning",
		gain_vernier < gain_main * 0.2 and gain_spin < gain_main * 0.2,
		"main gained %d px, the manoeuvring station %d, a vernier %d"
		% [gain_main, gain_vernier, gain_spin])
	Input.action_release("thrust_forward")

	await _pose(ship, cam, 0.0)
	await _settle()
	var off_strafe := _shot(_save("12_jets_strafe_idle"), ship, cam)
	Input.action_press("strafe_right")
	for i in 30:
		await physics_frame
	await _settle()
	var on_strafe := _shot(_save("13_jets_strafe"), ship, cam)
	var sb := _jet_gain(off_strafe, on_strafe, _anchor("StrafeToStarboard"))
	var sp := _jet_gain(off_strafe, on_strafe, _anchor("StrafeToPort"))
	var aft := _jet_gain(off_strafe, on_strafe, _anchor("MainAft"))
	_expect("E lights the station that pushes to starboard", sb > 60,
		"%d lit px gained at StrafeToStarboard" % sb)
	_expect("and the mirror station stays dark", sp < sb * 0.25,
		"%d px gained at StrafeToStarboard, %d at its mirror" % [sb, sp])
	_expect("the main engine stays dark on a pure side slip", aft < sb * 0.25,
		"%d px at the main station against %d at the vernier" % [aft, sb])
	Input.action_release("strafe_right")
	# Three frames a sample: the whole fade is the group's ~0.15 s power fall plus
	# 0.12 s of visual tail, so a coarser clock only ever catches a flame already
	# out, and a finer one measures the same frame twice.
	var trail: Array[int] = []
	for i in 8:
		for k in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		trail.append(_jet_gain(off_strafe,
			_shot(_save("14_fade_%02d" % i), ship, cam),
			_anchor("StrafeToStarboard")))
	# The claim is a slope, not a shape: most of the burn still on screen a few
	# frames after the release, a fraction of it two samples later, and by the end
	# nothing above the sub-pixel noise of a hull sliding under a 44 px window -
	# which elsewhere in this run measures well under twenty pixels.
	_expect("a released group dims over frames rather than vanishing",
		trail[0] > sb * 0.4 and trail[1] < trail[0] and trail[3] < trail[1]
		and trail[7] < 25,
		"%s against a full-burn %d px" % [str(trail), sb])

	await _pose(ship, cam, -PI * 0.5)
	ship.linear_velocity = Vector2(600.0, 0.0)
	await _settle()
	var off_brake := _shot(_save("15_jets_brake_idle"), ship, cam)
	Input.action_press("thrust_backward")
	for i in 30:
		await physics_frame
	await _settle()
	var on_brake := _shot(_save("16_jets_brake"), ship, cam)
	var retro := 0
	var retro_names := ""
	# Which way the brakes are actually pushing, and every station's own number: a
	# wrong station being alight has to be visible as a wrong name, not as a count
	# that merely says "not two".
	var push := _ship.thrust_direction()
	for a in _fx().anchors("brake"):
		var gain := _jet_gain(off_brake, on_brake, a)
		if gain > 60:
			retro += 1
		retro_names += "%s=%d(%.2f) " % [a.name, gain, a.thrust_world().dot(push)]
	var retro_main := _jet_gain(off_brake, on_brake, _anchor("MainAft"))
	_expect("the retro burn lights brake stations, and only the aimed ones",
		retro >= 1 and retro <= 2,
		"%d of %d alight, push %s: %s" % [retro, _fx().anchors("brake").size(),
		str(push), retro_names])
	var misaimed := 0
	for a in _fx().anchors("brake"):
		if _jet_gain(off_brake, on_brake, a) > 50 and a.thrust_world().dot(push) < 0.4:
			misaimed += 1
	_expect("not one of them is lit against the push it cannot serve",
		misaimed == 0, "%d stations alight while aiming away" % misaimed)
	_expect("the brake picture is not the main engine pretending",
		retro_main < 30, "%d px gained at the main station" % retro_main)
	Input.action_release("thrust_backward")

	await _pose(ship, cam, 0.0)
	await _settle()
	var off_spin := _shot(_save("17_jets_spin_idle"), ship, cam)
	Input.action_press("turn_left")
	for i in 30:
		await physics_frame
	await _settle()
	var on_spin := _shot(_save("18_jets_spin"), ship, cam)
	var counts := _spin_counts(off_spin, on_spin)
	_expect("A lights the counter-clockwise pair and not the clockwise one",
		counts[1] == 2 and counts[0] == 0,
		"%d counter-clockwise and %d clockwise stations alight" % [counts[1], counts[0]])
	Input.action_release("turn_left")
	# Re-posed, and with its own idle frame, before the reverse is judged. Left as
	# it is, the hull is at whatever heading the first spin handed over, so the
	# mirror station's window sits across a different edge of the metal - and a
	# counter vernier still going out is counted as one still burning. Same pose,
	# a full second for the pair to finish fading, then press the other rudder.
	await _pose(ship, cam, 0.0)
	for i in 60:
		await process_frame
	await _settle()
	var off_reverse := _shot(_save("19a_jets_spin_idle_reversed"), ship, cam)
	Input.action_press("turn_right")
	for i in 40:
		await physics_frame
	await _settle()
	var on_reverse := _shot(_save("19_jets_spin_reversed"), ship, cam)
	counts = _spin_counts(off_reverse, on_reverse)
	_expect("D takes the picture over with the turn",
		counts[0] == 2 and counts[1] == 0,
		"%d clockwise and %d counter-clockwise stations alight" % [counts[0], counts[1]])
	Input.action_release("turn_right")

	# every group at once is the worst case for the frame budget and for the picture
	await _pose(ship, cam, 0.0)
	await _settle()
	var off_all := _shot(_save("20_jets_all_idle"), ship, cam)
	Input.action_press("thrust_forward")
	Input.action_press("strafe_left")
	Input.action_press("turn_right")
	Input.action_press("thrust_backward")
	var worst := 0.0
	for i in 120:
		await process_frame
		worst = maxf(worst, Performance.get_monitor(Performance.TIME_PROCESS))
	await _settle()
	var on_all := _shot(_save("21_jets_all_at_once"), ship, cam)
	var burning_stations := 0
	for a in _fx().anchors():
		if _jet_gain(off_all, on_all, a) > 60:
			burning_stations += 1
	_expect("four levers held burn four groups' stations at once",
		burning_stations >= 4, "%d stations alight" % burning_stations)
	_expect("every group burning at once still holds the frame", worst < 40.0,
		"worst process frame %.1f ms" % worst)
	_expect("the hull is still readable under all that light",
		_airframe_reads(on_all["img"], "all groups burning", cam, ship) == 0, "")
	_release_keys()
	# a whole second, not a settle: the main engine's shutdown ramp is 0.5 s and the
	# jets fade for another 0.12 s on top of it, so a frame taken too early is a
	# ship that is honestly still going out
	for i in 60:
		await process_frame
	await _settle()
	var off_again := _shot(_save("22_jets_released"), ship, cam)
	# per station, not summed: the hull shifts by a fraction of a pixel between two
	# frames at different camera lags, and eleven of those add up to a number that
	# looks like leftover flame but is really just the metal moving.
	var still_alight := 0
	var worst_gain := 0
	var worst_name := ""
	for a in _fx().anchors():
		var gain := _jet_gain(off_all, off_again, a)
		if gain > 60:
			still_alight += 1
		if gain > worst_gain:
			worst_gain = gain
			worst_name = String(a.name)
	_expect("nothing is left burning when every lever comes off", still_alight == 0,
		"%d stations still above the band, brightest %s at %d px" % [still_alight,
		worst_name, worst_gain])
	# --------------------------------------- the assists, in pixels (sub-stage 1.3)
	# 1.3's claim is 1.2's claim moved one layer up: an assist may change the picture
	# only by changing what the engines are actually doing. Nothing below looks for a
	# new effect - each check compares one station's flame between two runs of the
	# same pose, and the burn being shown has to be the burn the hull is spending.
	ship.stabilization.set_enabled(false)
	await _pose(ship, cam, 0.0)
	ship.linear_velocity = ship.starboard() * 320.0
	# Physics frames, not draw frames: the ramps being waited on are the model's, and
	# an unthrottled window serves draw frames far faster than 60 of them - waiting on
	# `process_frame` here photographed a stabilizer that was only half up.
	for i in 60:
		await physics_frame
	await _settle()
	var base_slide := _shot(_save("23_slide_unassisted"), ship, cam)
	ship.stabilization.set_enabled(true)
	await _pose(ship, cam, 0.0)
	ship.linear_velocity = ship.starboard() * 320.0
	for i in 60:
		await physics_frame
	await _settle()
	var on_slide := _shot(_save("24_slide_stabilized"), ship, cam)
	# The bar is a fraction of the pilot's own burn at the same station, measured
	# earlier in this same run (`sb`) - not a constant guessed from outside. The
	# stabilizer borrows `stabilization_linear_power` of the group, so the flame has to
	# be plainly there while being plainly smaller than a keyed burn.
	var port_gain := _jet_gain(base_slide, on_slide, _anchor("StrafeToPort"))
	var star_gain := _jet_gain(base_slide, on_slide, _anchor("StrafeToStarboard"))
	_expect("the stabilizer burns a station with no key held",
		port_gain > sb * 0.25,
		"%d px at StrafeToPort with %.2f borrowed, the pilot's own burn is %d px" % [
			port_gain, ship.engines.strafe_power, sb])
	_expect("and only the one that pushes against the drift",
		star_gain < port_gain * 0.25,
		"%d px at the mirror station, %d at the burning side" % [star_gain, port_gain])
	var slide_main := _jet_gain(base_slide, on_slide, _anchor("MainAft"))
	_expect("a corrected slide does not borrow the engine's flame", slide_main < 30,
		"%d px at the main station" % slide_main)
	ship.stabilization.set_enabled(false)

	await _pose(ship, cam, -PI * 0.5)
	ship.linear_velocity = Vector2(600.0, 0.0)
	await _settle()
	var off_eb := _shot(_save("25_eb_idle"), ship, cam)
	Input.action_press("emergency_brake")
	for i in 20:
		await physics_frame
	await _settle()
	var on_eb := _shot(_save("26_eb_burning"), ship, cam)
	var eb_push := ship.thrust_direction()
	var eb_lit := 0
	var eb_names := ""
	for a in _fx().anchors("brake"):
		var eb_gain := _jet_gain(off_eb, on_eb, a)
		if eb_gain > 60:
			eb_lit += 1
		eb_names += "%s=%d(%.2f) " % [a.name, eb_gain, a.thrust_world().dot(eb_push)]
	var eb_main := _jet_gain(off_eb, on_eb, _anchor("MainAft"))
	_expect("Space alone lights the retro plant it is burning",
		eb_lit >= 1 and eb_lit <= 2,
		"%d of %d alight, push %s: %s" % [eb_lit, _fx().anchors("brake").size(),
			str(eb_push), eb_names])
	_expect("and the main engine is not part of an emergency stop", eb_main < 30,
		"%d px gained at the main station" % eb_main)
	_release_keys()

	# Boost is the one effect 1.3 is allowed to make *bigger*, and it has to be bigger
	# because the engine is genuinely over-authorised - so the test is not "a brighter
	# pixel somewhere" but "the same nozzle, measured further down its own exhaust".
	ship.boost.boost_charge = 1.0
	ship.boost.cut_off = false
	await _pose(ship, cam, 0.0)
	await _settle()
	var off_boost := _shot(_save("27_boost_idle"), ship, cam)
	Input.action_press("thrust_forward")
	for i in 45:
		await physics_frame
	await _settle()
	var on_plain := _shot(_save("28_engine_plain"), ship, cam)
	Input.action_press("boost")
	for i in 30:
		await physics_frame
	await _settle()
	var on_boost := _shot(_save("29_boost_main"), ship, cam)
	_release_keys()
	var main_anchor := _anchor("MainAft")
	var near_plain := _jet_gain(off_boost, on_plain, main_anchor)
	var near_boost := _jet_gain(off_boost, on_boost, main_anchor)
	var far_plain := _gain_at(off_boost, on_plain, main_anchor, 12.0, 46.0)
	var far_boost := _gain_at(off_boost, on_boost, main_anchor, 12.0, 46.0)
	_expect("boost burns the main nozzle harder than W alone",
		near_boost > near_plain * 1.05,
		"%d px at full authority, %d boosted" % [near_plain, near_boost])
	# Not "the plain flame does not reach here" - at this size it does, a little. The
	# claim that is actually true and worth holding is that the same window down the
	# exhaust fills in as the engine is over-authorised, because `length` is drawn from
	# a power that has gone past 1.0.
	_expect("and its exhaust reaches further down the same void",
		far_boost > far_plain * 1.3 and far_boost > 60,
		"%d px forty world px aft while boosted, %d while plain" % [far_boost,
			far_plain])
	_expect("the hull is still the brightest thing it owns under a boost",
		_airframe_reads(on_boost["img"], "boosted", cam, ship) == 0, "")
	sky.visible = true
	field.visible = true

	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  shots in ", OUT)
	quit(1 if _failed else 0)


## How many clockwise [0] and counter-clockwise [1] verniers are alight, measured
## as gained pixels against the same pose with the rudder untouched. Each station
## prints its own number, because "2 and 1" says only that something is wrong; the
## names say which nozzle the picture is blaming.
func _spin_counts(off: Dictionary, on: Dictionary) -> Array[int]:
	var out: Array[int] = [0, 0]
	var detail := ""
	for a in _fx().anchors("rotation"):
		var gain := _jet_gain(off, on, a)
		if gain > 60:
			out[0 if a.spin > 0 else 1] += 1
		detail += "%s=%d " % [String(a.name), gain]
	print("    ", detail)
	return out


## The spec-6 pose: flying to the right, nose turned straight up, retro burn lit.
## The same state, twice, so the overlay can be compared against its own absence.
func _broadside(ship: ShipController, cam: Camera2D) -> void:
	cam.set_view_zoom(cam.base_zoom)
	Input.action_release("thrust_forward")
	Input.action_release("turn_left")
	Input.action_release("turn_right")
	ship.rotation = -PI * 0.5
	ship.angular_velocity = 0.0
	ship.linear_velocity = Vector2(600.0, 0.0)
	ship.global_position = Vector2(0, 1000)
	cam.snap()
	Input.action_press("thrust_backward")
	for i in 20:
		await physics_frame


func _wait_idle(frames: int) -> void:
	for i in frames:
		await process_frame


func _settle() -> void:
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(tag: String) -> Image:
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT + tag + ".png")
	print("  saved ", tag, " ", img.get_size())
	return img


## Where a world point lands on the screen: the camera's centre is a known world
## point and `zoom` is the world-to-screen scale, so this is arithmetic rather than
## a server call whose direction is easy to get backwards. Sampling the middle of
## the frame instead would be sampling empty space - the camera trails the ship by
## a hundred and more world pixels while it flies.
func _project(world: Vector2, cam: Camera2D, size: Vector2) -> Vector2:
	return (world - cam.get_screen_center_position()) * cam.zoom + size / 2.0


func _box(center: Vector2, half: Vector2, cam: Camera2D, size: Vector2) -> Rect2:
	var at := _project(center, cam, size)
	var extent := half * cam.zoom.x
	return Rect2(at - extent, extent * 2.0)


## The patch of screen the hull occupies, and the patch behind the nozzles.
func _hull_box(img: Image, cam: Camera2D, ship: Node2D) -> Rect2:
	return _box(ship.global_position, HULL_BOX, cam, Vector2(img.get_size()))


func _aft_box(img: Image, cam: Camera2D, ship: RigidBody2D) -> Rect2:
	return _box(ship.global_position - ship.forward() * AFT_REACH, AFT_BOX, cam,
		Vector2(img.get_size()))


## Lit pixels inside a box, clamped to what the image actually holds. The default
## threshold is the hull's own brightness; a flame is measured far below it.
func _lit(box: Rect2, img: Image, threshold := 0.4) -> int:
	var limit := Vector2(img.get_size()) - Vector2(1, 1)
	var count := 0
	for y in range(int(clampf(box.position.y, 0.0, limit.y)),
			int(clampf(box.end.y, 0.0, limit.y))):
		for x in range(int(clampf(box.position.x, 0.0, limit.x)),
				int(clampf(box.end.x, 0.0, limit.x))):
			if img.get_pixel(x, y).get_luminance() > threshold:
				count += 1
	return count


## How many pixels of one colour a window holds, and where they sit on average -
## the centroid is what says which side of the hull an arrow was drawn on. Every
## second pixel is skipped: an arrow is 150 px of screen, so half a thousand
## samples is plenty to place it.
func _tint(img: Image, color: Color, window: Rect2, stride := 2) -> Dictionary:
	var limit := Vector2(img.get_size()) - Vector2(1, 1)
	var n := 0
	var sx := 0.0
	var sy := 0.0
	for y in range(int(clampf(window.position.y, 0.0, limit.y)),
			int(clampf(window.end.y, 0.0, limit.y)), stride):
		for x in range(int(clampf(window.position.x, 0.0, limit.x)),
				int(clampf(window.end.x, 0.0, limit.x)), stride):
			var p := img.get_pixel(x, y)
			if absf(p.r - color.r) < 0.06 and absf(p.g - color.g) < 0.06 and absf(p.b - color.b) < 0.06:
				n += 1
				sx += float(x)
				sy += float(y)
	return {"n": n, "cx": sx / maxf(float(n), 1.0), "cy": sy / maxf(float(n), 1.0)}


## Average brightness of the whole frame, sampled on a grid: the sky is a lot of dim
## cloud plus a few stars, and a mean is what tells a dim sky from a blown-out one.
func _mean(img: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)


## The airframe has to read against the sky rather than float in a black box: enough
## of the hull's own box lit, and the frame as a whole dim enough that the hull is
## still the brightest thing in it. Returns how many of the two checks failed, so a
## caller can fold the picture into a bigger assertion.
func _airframe_reads(img: Image, when: String, cam: Camera2D, ship: Node2D) -> int:
	var before := _failed
	var box := _hull_box(img, cam, ship)
	var lit := _lit(box, img)
	var share := float(lit) / maxf(box.get_area(), 1.0)
	var mean := _mean(img)
	_expect("the airframe reads on the sky (%s)" % when, share > 0.05,
		"%.1f%% of the hull box lit, mean frame %.4f" % [share * 100.0, mean])
	_expect("the sky stays behind the ship (%s)" % when, mean < 0.12,
		"mean frame luminance %.4f" % mean)
	return _failed - before


# ------------------------------------------------- 1.2 plumbing: the jet layer --

var _ship: ShipController
var _cam: Camera2D


func _fx() -> EngineVisuals:
	return _ship.get_node("EngineFx") as EngineVisuals


func _anchor(name: String) -> EngineNozzle:
	for a in _fx().anchors():
		if String(a.name) == name:
			return a
	return null


## Teleport the hull into the clear corridor, dead still, at `heading`, and hold it
## there until the physics server has taken the placement. The jets are compared
## against their own stations, so every pose has to start from the same place.
func _pose(ship: ShipController, cam: Camera2D, heading: float) -> void:
	_release_keys()
	cam.set_view_zoom(cam.base_zoom)
	ship.global_position = Vector2(0, 1000)
	ship.rotation = heading
	ship.linear_velocity = Vector2.ZERO
	ship.angular_velocity = 0.0
	cam.snap()
	for i in 12:
		await physics_frame
		# A transform written on a body is taken by the server on its own clock, and
		# a step that begins before that lands the hull back where the last pose
		# left it - so the placement is re-asserted until it sticks.
		if ship.global_position.distance_to(Vector2(0, 1000)) > 0.5:
			ship.global_position = Vector2(0, 1000)
			ship.linear_velocity = Vector2.ZERO
		if absf(wrapf(ship.rotation - heading, -PI, PI)) > 0.001:
			ship.rotation = heading
			ship.angular_velocity = 0.0


func _release_keys() -> void:
	for a in ["thrust_forward", "thrust_backward", "turn_left", "turn_right",
			"strafe_left", "strafe_right", "toggle_stabilization", "emergency_brake",
			"boost"]:
		Input.action_release(a)


## A captured frame, bound to the transforms it was taken with: the hull's place
## and attitude (so a station's world position can be rebuilt for the moment the
## picture happened) and the camera's centre and scale. Without that binding, an
## idle frame and a burning frame measured "the same window" at two different
## places on the hull, and the difference was the hull, not the flame.
func _shot(img: Image, ship: ShipController, cam: Camera2D) -> Dictionary:
	return {"img": img, "hull": ship.global_position, "rot": ship.rotation,
		"centre": cam.get_screen_center_position(), "zoom": cam.zoom.x,
		"size": Vector2(img.get_size())}


## Bright pixels in the patch of void a station's exhaust is drawn into, projected
## through the transform recorded with the frame. The window is deliberately *not*
## centred on the nozzle: the flame leaves the hull pointing away from the push, and
## sampling the sky it paints - rather than the station itself, which sits on the
## hull's own bright edge - is what makes a burning jet measurable. A sprite laid
## over a bright hull pixel can be darker than the metal it covers, and an idle
## frame would then "gain" nothing while a burning one lost pixels.
##
## `reach` is how far out along the exhaust the window sits: 16 is the body of the
## jet, and a larger number samples the tip - which is how a boost's longer plume is
## told apart from the same nozzle burning at ordinary authority.
func _lit_at(shot: Dictionary, anchor: EngineNozzle, radius: float = 22.0,
		reach: float = 16.0) -> int:
	if anchor == null:
		return 0
	var at: Vector2 = shot["hull"] + (anchor.position
		- anchor.thrust_local * reach).rotated(shot["rot"])
	var centre: Vector2 = shot["centre"]
	var zoom: float = shot["zoom"]
	var size: Vector2 = shot["size"]
	var start := (at - centre) * zoom + size / 2.0
	var extent := Vector2(radius, radius) * zoom
	var box := Rect2(start - extent, extent * 2.0)
	# 0.22, not the 0.4 the hull check uses: the void behind a nozzle sits at
	# luminance 0.03, and a muted cold flame tapers through 0.1-0.3 at its edges.
	# At 0.4 only the white core of the main engine counts at all, and a vernier
	# that is plainly burning measures nine pixels.
	return _lit(box, shot["img"], JET_LUMINANCE)


## Lit pixels a station gained between an idle frame and a burning one. Each frame
## is measured with its own transforms, so the hull's brightness cancels and what
## is left is the flame - the only thing this layer is allowed to add.
func _jet_gain(off: Dictionary, on: Dictionary, anchor: EngineNozzle) -> int:
	return _lit_at(on, anchor) - _lit_at(off, anchor)


## The same gain measured at a chosen distance along the exhaust: the way to see a
## plume that reaches further, not merely one that is brighter where it already was.
func _gain_at(off: Dictionary, on: Dictionary, anchor: EngineNozzle,
		radius: float, reach: float) -> int:
	return _lit_at(on, anchor, radius, reach) - _lit_at(off, anchor, radius, reach)


func _expect(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + "   " + detail)
	if not ok:
		_failed += 1
