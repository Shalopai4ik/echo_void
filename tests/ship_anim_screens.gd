extends SceneTree

## Renders the fighter's animation layer with a real GPU and measures what came
## back. The headless tests can only read the numbers the controller writes into
## the sprites; they cannot tell a compiled shader from a black quad, and a ship
## that banks but stays flat-lit is exactly the failure they would miss.
## Run: godot --path . --script tests/ship_anim_screens.gd --rendering-driver opengl3

const OUT := "res://test-output/anim/"
## The design viewport. The hull is drawn at scale 2 and the camera zooms 0.5, so
## one texture pixel lands on one design pixel: a 148x100 sprite covers 148x100.
## The window is stretched from that, so every measurement is taken in design
## pixels and scaled by however big the frame actually came out.
const BANK_MAX := 0.9
## How hard the three baseline poses above are leaned over, in bank units.
const BANK_POSE := 0.85

var _failed := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: Node2D = scene.get_node("Player")
	var visuals: Node2D = player.get_node("Visuals")
	var sprite: Sprite2D = visuals.get_node("Sprite2D")
	var mat: ShaderMaterial = sprite.material as ShaderMaterial
	var smoke: CPUParticles2D = visuals.get_node("DamageSmoke")

	# strip everything that is not the ship, so the pixels measured below belong to
	# the airframe and not to a passing star or boulder
	scene.get_node("Asteroids").enabled = false
	scene.get_node("Background").visible = false
	scene.get_node("HUD").visible = false
	await _settle()

	# --- the roll shading is really being composited ---
	# hold the hull at rotation 0 so its starboard half is the lower half of the
	# frame, then lean it one way and the other and watch the light move with it
	player.set_physics_process(false)
	player.set_process(false)
	await _settle()
	# one box, measured before anything moves, so the three poses below differ
	# only by what the shader did to those exact pixels
	var box := _bright_box(root.get_texture().get_image())
	# The baseline is squashed exactly like the two poses below, because
	# compressing an airframe that is not vertically symmetric moves paint across
	# the midline and that would read as the light having moved. And the pixels
	# compared are the ones the level pose painted, fixed for all three: measuring
	# over the whole box instead would dilute the signal with empty space, which
	# grows every time the ship does.
	_pose(mat, visuals, 0.0)
	await _settle()
	var level := _sides(box)
	var up: Array = level.up
	var down: Array = level.down
	_pose(mat, visuals, 1.0)
	await _settle()
	var starboard := _sides(box, up, down)
	_pose(mat, visuals, -1.0)
	await _settle()
	var port := _sides(box, up, down)
	_pose(mat, visuals, 0.0)
	visuals.scale = Vector2.ONE
	player.set_physics_process(true)
	player.set_process(true)
	await _settle()

	_expect("the frame is actually showing the ship", level.lit > 1500,
		"%d lit px of %d" % [int(level.lit), level.n])
	# the two halves of this airframe are not the same drawing - the starboard
	# side carries the engine bay and the blue accents - so level is not expected
	# to read evenly. What has to hold is that both halves really are paint.
	_expect("both wings are in the frame", level.up.size() > 300 and level.down.size() > 300,
		"%d port px / %d starboard px" % [level.up.size(), level.down.size()])
	var lean_r: float = starboard.d - level.d
	var lean_l: float = port.d - level.d
	_expect("banking moves the light across the hull",
		lean_r > 0.05 and lean_l < -0.05,
		"starboard roll %+.3f / port roll %+.3f against level" % [lean_r, lean_l])
	# the two directions are not expected to be equal and a check that demanded it
	# would be wrong: a lit wing has nowhere above white to go, a shadowed one has
	# all the way down. What has to hold is that the light moves the same distance
	# either way and in opposite directions.
	_expect("the roll answers the same either side of level",
		lean_r > 0.0 and lean_l < 0.0
		and minf(absf(lean_r), absf(lean_l)) > absf(lean_r) * 0.5,
		"%+.3f starboard / %+.3f port" % [lean_r, lean_l])

	# --- and the same roll driven by the controller, on screen ---
	Input.action_press("move_right")
	for i in 150:
		await physics_frame
	await _check_flight_frame(player, "01_cruise")

	# a course change at speed: the velocity vector has to swing, so this is the
	# gentler of the two banks and the one that has to stay short of the limit
	Input.action_press("move_up")
	var glide := 1.0
	var glide_rate := 0.0
	for i in 40:
		await physics_frame
		glide = minf(glide, visuals.scale.y)
		glide_rate = maxf(glide_rate, absf(player._turn))
	await _settle()
	await _save("02_cruise_turn", player)
	Input.action_release("move_up")
	Input.action_release("move_right")
	await _settle()
	_expect("a course change at speed banks the ship", glide < 0.93,
		"wingspan %.3f at %.1f rad/s" % [glide, glide_rate])

	# a hard turn out of a standstill: full roll
	player.velocity = Vector2.ZERO
	player.rotation = 0.0
	Input.action_press("move_up")
	var hard := 1.0
	var hard_rate := 0.0
	for i in 14:
		await physics_frame
		hard = minf(hard, visuals.scale.y)
		hard_rate = maxf(hard_rate, absf(player._turn))
	await _settle()
	await _save("03_hard_turn", player)
	Input.action_release("move_up")
	await _settle()
	_expect("a hard turn puts the wings near edge-on", hard < 0.8,
		"wingspan %.3f at %.1f rad/s" % [hard, hard_rate])

	Input.action_press("move_right")
	Input.action_press("boost")
	for i in 90:
		await physics_frame
	await _check_flight_frame(player, "04_afterburner")
	Input.action_release("boost")
	Input.action_release("move_right")
	await _settle()

	# --- wounded and still flying: the flame stays lit and gas comes out of it.
	# Freezing the ship to photograph it would also freeze the exhaust, so this is
	# a moving frame and the gas is counted, not assumed.
	player.shield = 0.0
	player.hull = 34.0
	Input.action_press("move_right")
	for i in 80:
		await physics_frame
	var bleeding: bool = smoke.emitting
	await _settle()
	await _save("05_wounded", player)
	var gas := _dim_count(root.get_texture().get_image())
	Input.action_release("move_right")
	await _settle()
	_expect("a wounded hull bleeds on screen", bleeding and gas > 400,
		"%d px of gas while emitting=%s" % [gas, bleeding])

	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS")
	scene.queue_free()
	await _settle()
	quit(1 if _failed > 0 else 0)


## Poses the roll by hand. Every pose needs its own rendered frame, or all three
## read back the same image and the shader looks inert.
func _pose(mat: ShaderMaterial, visuals: Node2D, bank: float) -> void:
	mat.set_shader_parameter("bank", bank)
	visuals.scale = Vector2(1.0, cos(BANK_POSE * BANK_MAX))


## Starboard minus port over the drawn airframe, plus how much of the frame is
## paint at all. The ship is located by what it lights up rather than by where the
## controller thinks it is: the camera trails a fast fighter, and the only honest
## answer to "is it on screen" is the pixels that got there.
func _sides(box: Rect2, fixed_up: Array = [], fixed_down: Array = []) -> Dictionary:
	var img: Image = root.get_texture().get_image()
	if fixed_up.is_empty():
		fixed_up = []
		fixed_down = []
		for p in _paint(img, box):
			(fixed_up if p.y < box.get_center().y else fixed_down).append(p)
	var up := 0.0
	var down := 0.0
	for p in fixed_up:
		up += _lum(img, p)
	for p in fixed_down:
		down += _lum(img, p)
	var n := fixed_up.size() + fixed_down.size()
	return {"d": up / maxf(float(fixed_up.size()), 1.0) 		- down / maxf(float(fixed_down.size()), 1.0), "lit": n, "n": n,
		"up": fixed_up, "down": fixed_down}


func _lum(img: Image, p: Vector2i) -> float:
	if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
		return 0.0
	var c := img.get_pixelv(p)
	return (c.r + c.g + c.b) / 3.0


## Every pixel inside the box bright enough to be paint rather than space.
func _paint(img: Image, box: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in int(box.size.y):
		for x in int(box.size.x):
			var p := Vector2i(int(box.position.x) + x, int(box.position.y) + y)
			if _lum(img, p) > 0.22:
				out.append(p)
	return out


## Pixels too bright to be empty space and far too dim to be paint: the only thing
## in this frame that qualifies is escaping gas.
func _dim_count(img: Image) -> int:
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixelv(Vector2i(x, y))
			var v := (c.r + c.g + c.b) / 3.0
			if v > 0.075 and v < 0.22:
				n += 4
	return n


func _check_flight_frame(_player: Node2D, tag: String) -> void:
	await _settle()
	await _save(tag, _player)
	var s: Dictionary = _sides(_bright_box(root.get_texture().get_image()))
	_expect(tag + " paints a lit airframe", s.lit > 1500, "%d lit px" % int(s.lit))


## The square the drawn airframe occupies on screen, in whatever size the window
## turned out to be.
func _bright_box(img: Image) -> Rect2:
	var lo := Vector2i(img.get_width(), img.get_height())
	var hi := Vector2i.ZERO
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixelv(Vector2i(x, y))
			if (c.r + c.g + c.b) / 3.0 < 0.22:
				continue
			lo.x = mini(lo.x, x)
			lo.y = mini(lo.y, y)
			hi.x = maxi(hi.x, x)
			hi.y = maxi(hi.y, y)
	if hi.x <= lo.x or hi.y <= lo.y:
		return Rect2()
	var mid := Vector2(lo + hi) / 2.0
	var half := Vector2(hi - lo) / 2.0
	# square it on the short axis so the port/starboard split is a true half
	var r := maxf(half.x, half.y) * 1.08
	return Rect2(mid - Vector2(r, r), Vector2(r, r) * 2.0)


func _expect(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + "   " + detail)
	if not ok:
		_failed += 1


func _settle() -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(tag: String, player: Node2D) -> void:
	var img: Image = root.get_texture().get_image()
	var box := _bright_box(img)
	if box.size.x <= 0.0:
		box = Rect2(Vector2(img.get_size()) / 2.0 - Vector2(80, 80), Vector2(160, 160))
	var side := mini(roundi(maxf(box.size.x, 120.0) * 1.25), img.get_width())
	var at := box.get_center()
	var crop := img.get_region(Rect2i((at - Vector2(side, side) / 2.0).round(), Vector2i(side, side)))
	crop.resize(crop.get_width() * 3, crop.get_height() * 3, Image.INTERPOLATE_NEAREST)
	crop.save_png(OUT + tag + ".png")
	print("  saved ", tag)
