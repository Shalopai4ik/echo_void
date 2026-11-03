extends SceneTree

## Headless smoke test for the ship controller.
## Run: godot --headless --path . --script tests/smoke_test.gd

const VIEW := Vector2(960, 540)
var _failed := false

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("PASS  ", name, "  ", detail)
	else:
		_failed = true
		print("FAIL  ", name, "  ", detail)

func _steps(count: int) -> void:
	for i in count:
		await physics_frame


## How far the drawn flame's own nozzle sits from the node origin. With
## centered = false and offset = -texture/2 it is exactly zero at any scale, and
## that is the property the engine animation leans on.
func _nozzle_error(sp: Sprite2D) -> float:
	if sp.texture == null:
		return 1e9
	var tex: Vector2 = sp.texture.get_size()
	return (sp.scale * (sp.offset + Vector2(tex.x, tex.y * 0.5))).length()

func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	# this test is about the controller; the belt has its own, and a rock in the
	# flight path would make every distance assertion below a coin flip
	scene.get_node("Asteroids").enabled = false
	root.add_child(scene)
	await process_frame
	await physics_frame

	var player: Node2D = scene.get_node("Player")
	var visuals: Node2D = player.get_node("Visuals")
	var sprite: Sprite2D = visuals.get_node("Sprite2D")
	var plume: Sprite2D = visuals.get_node("EnginePlume")
	var core: Sprite2D = visuals.get_node("EngineCore")
	var glow: Sprite2D = visuals.get_node("EngineGlow")
	var sparks: CPUParticles2D = visuals.get_node("ExhaustSparks")
	var smoke: CPUParticles2D = visuals.get_node("DamageSmoke")

	_check("start position", player.position == Vector2(480, 270), str(player.position))
	_check("texture loaded", sprite.texture != null and sprite.texture.get_size() == Vector2(148, 100),
		"size=" + str(sprite.texture.get_size() if sprite.texture else Vector2.ZERO))
	_check("sprite scale", sprite.scale == Vector2(2, 2), str(sprite.scale))
	_check("plume texture", plume.texture != null and plume.texture.get_size() == Vector2(60, 18),
		"size=" + str(plume.texture.get_size() if plume.texture else Vector2.ZERO))

	var hull: Image = sprite.texture.get_image()
	# the airframe is drawn nose-along-+X, because the controller steers with
	# `rotation = velocity.angle()`; a square canvas would let a rotated import
	# pass every other size check, so pin the tip itself
	_check("hull faces +X", hull.get_pixel(144, 50).a > 0.9 and hull.get_pixel(50, 98).a < 0.01,
		"nose=%f side=%f" % [hull.get_pixel(144, 50).a, hull.get_pixel(50, 98).a])
	# the airframe stops at the nozzle mouth: nothing is painted behind it, so the
	# animated exhaust is the only thing that can occupy that space
	_check("exhaust cut from hull", hull.get_pixel(0, 50).a < 0.01 and hull.get_pixel(2, 50).a < 0.01,
		"alpha=%f/%f" % [hull.get_pixel(0, 50).a, hull.get_pixel(2, 50).a])
	# the traced tail carries its own nozzle: a dark throat at the very back with
	# the metal of the tail root brightening forward of it. A tail simply painted
	# black would pass the cut test above and still have nothing for a jet to
	# come out of.
	_check("the engine is there with the fire gone",
		hull.get_pixel(4, 50).v < 0.2 and hull.get_pixel(38, 50).v > 0.5,
		"mouth=%.2f rim=%.2f" % [hull.get_pixel(4, 50).v, hull.get_pixel(38, 50).v])

	_check("engine dark at rest", not plume.visible and not core.visible,
		"%s/%s" % [plume.visible, core.visible])
	_check("glow hidden at rest", not glow.visible, str(glow.visible))

	# --- W: up ---
	var start := player.position
	Input.action_press("move_up")
	await _steps(40)
	_check("engine lit while flying", plume.visible and core.visible,
		"%s/%s" % [plume.visible, core.visible])
	_check("plume stretches", plume.scale.x > 1.0, "scale=" + str(plume.scale))
	Input.action_release("move_up")
	_check("W moves up", player.position.y < start.y - 100.0,
		"dy=" + str(player.position.y - start.y))
	_check("W rotates to -90deg", absf(rad_to_deg(player.rotation) + 90.0) < 5.0,
		"rot=" + str(rad_to_deg(player.rotation)))
	await _steps(90)
	_check("glide decays", player.velocity.length() < 5.0, "v=" + str(player.velocity.length()))
	_check("engine out when stopped", not plume.visible and not core.visible,
		"%s/%s" % [plume.visible, core.visible])

	# --- D: right ---
	start = player.position
	Input.action_press("move_right")
	await _steps(40)
	Input.action_release("move_right")
	_check("D moves right", player.position.x > start.x + 100.0,
		"dx=" + str(player.position.x - start.x))
	_check("D rotates to 0deg", absf(rad_to_deg(player.rotation)) < 5.0,
		"rot=" + str(rad_to_deg(player.rotation)))
	await _steps(60)

	# --- diagonal ---
	player.position = Vector2(480, 270)
	player.velocity = Vector2.ZERO
	player.rotation = 0.0
	start = player.position
	Input.action_press("move_left")
	Input.action_press("move_up")
	await _steps(40)
	Input.action_release("move_left")
	Input.action_release("move_up")
	_check("diagonal left-up", player.position.x < start.x - 50.0 and player.position.y < start.y - 50.0,
		"d=" + str(player.position - start))
	await _steps(60)

	# --- unbounded flight: the ship leaves the starting viewport for good ---
	player.position = Vector2(480, 270)
	player.velocity = Vector2.ZERO
	var bg := scene.get_node_or_null("Background")
	_check("background instanced", bg != null, str(bg))
	Input.action_press("move_right")
	Input.action_press("move_down")
	await _steps(240)
	Input.action_release("move_right")
	Input.action_release("move_down")
	_check("flies past the viewport",
		player.position.x > VIEW.x + 400.0 and player.position.y > VIEW.y + 400.0,
		"pos=" + str(player.position))

	# --- and the camera keeps the ship framed ---
	var cam := player.get_node_or_null("Camera2D") as Camera2D
	_check("camera exists and is current", cam != null and cam.is_current(),
		"current=%s" % str(cam.is_current() if cam else false))
	await _steps(180)
	var gap: float = cam.global_position.distance_to(player.global_position)
	_check("camera caught up with the ship", gap < 8.0, "gap=%.2f" % gap)
	await _steps(30)
	_check("camera holds position while gliding",
		cam.global_position.distance_to(player.global_position) < 8.0,
		"gap=%.2f pos=%s" % [cam.global_position.distance_to(player.global_position),
							 str(player.position)])

	# --- the parallax world is still full of content that far out ---
	if bg != null:
		var st: Dictionary = bg.stats()
		_check("background populated far from origin", int(st.nodes) > 20, str(st))

	# --- Shift boost: faster, bigger flame, brighter glow ---
	Input.action_press("move_left")
	var normal_speed := 0.0
	var cruise_flame := 0.0
	var cruise_glow := 0.0
	for i in 30:
		await physics_frame
		normal_speed = player.velocity.length()
		cruise_flame = maxf(cruise_flame, plume.scale.x)
		cruise_glow = maxf(cruise_glow, glow.modulate.a)

	Input.action_press("boost")
	var boosted_speed := 0.0
	var boosted_flame := 0.0
	var glow_alpha := 0.0
	var sparking := false
	for i in 30:
		await physics_frame
		boosted_speed = player.velocity.length()
		boosted_flame = maxf(boosted_flame, plume.scale.x)
		glow_alpha = maxf(glow_alpha, glow.modulate.a)
		sparking = sparking or sparks.emitting
	Input.action_release("boost")
	Input.action_release("move_left")

	_check("afterburner throws sparks", sparking, str(sparking))
	_check("boost speeds up", boosted_speed > normal_speed * 1.4,
		"normal=%.1f boosted=%.1f" % [normal_speed, boosted_speed])
	_check("boost flame bigger", boosted_flame > cruise_flame * 1.2,
		"cruise=%.2f boosted=%.2f" % [cruise_flame, boosted_flame])
	_check("boost glow brighter", glow.visible and glow_alpha > 0.3,
		"alpha=%.2f" % glow_alpha)
	_check("boost floods the halo", glow_alpha > cruise_glow * 2.0,
		"cruise=%.2f boosted=%.2f" % [cruise_glow, glow_alpha])

	# --- the exhaust column pivots on the nozzle, it never tears off the hull ---
	# each layer is drawn uncentred with offset = -texture/2 so that the middle of
	# its right edge lands on the node origin; that is what lets scale.x stretch
	# the flame aft and rotation wag it without the nozzle sliding off the tail
	var drift := 0.0
	for sp in [plume, core, glow]:
		drift = maxf(drift, _nozzle_error(sp))
	_check("flame pivots on its own nozzle", drift < 0.01,
		"%.3f px off at every scale" % drift)

	Input.action_press("move_up")
	var slipped := 0.0
	for i in 40:
		await physics_frame
		var tex: Vector2 = plume.texture.get_size()
		var edge: Vector2 = plume.to_global(plume.scale * (plume.offset + Vector2(tex.x, tex.y * 0.5)))
		slipped = maxf(slipped, edge.distance_to(player.to_global(player.NOZZLE)))
	Input.action_release("move_up")
	_check("nozzle stays pinned through a turn", slipped < 0.6, "%.2f px of slip" % slipped)

	# --- the airframe rolls into a turn, and only the paint does ---
	player.position = Vector2(480, 270)
	player.velocity = Vector2.ZERO
	player.rotation = 0.0
	await _steps(50)
	_check("level when flying straight", absf(visuals.scale.y - 1.0) < 0.02,
		"wingspan=%.3f" % visuals.scale.y)
	_check("sparks cold at rest", not sparks.emitting, str(sparks.emitting))

	Input.action_press("move_up")
	var bank_mat: ShaderMaterial = sprite.material as ShaderMaterial
	var squeezed := 1.0
	var leaned := 0.0
	for i in 26:
		await physics_frame
		squeezed = minf(squeezed, visuals.scale.y)
		leaned = maxf(leaned, absf(bank_mat.get_shader_parameter("bank")))
	Input.action_release("move_up")
	_check("rolls into the turn", squeezed < 0.92, "wingspan squeezed to %.3f" % squeezed)
	_check("the roll reaches the shader", leaned > 0.2, "bank=%.2f" % leaned)
	var hull_sq: float = player.get_node("Hull").global_transform.get_scale().y
	_check("collision keeps its wingspan", is_equal_approx(hull_sq, 1.0), "hull scale=%.3f" % hull_sq)

	await _steps(60)
	_check("rolls back out", absf(visuals.scale.y - 1.0) < 0.02, "wingspan=%.3f" % visuals.scale.y)

	# --- lighting off is an event, not a switch ---
	player.velocity = Vector2.ZERO
	await _steps(40)
	Input.action_press("move_right")
	await _steps(2)
	var lit: float = player._flare
	await _steps(70)
	var settled: float = player._flare
	Input.action_release("move_right")
	_check("lighting off flares", lit > 0.7, "flare=%.2f in the first frames" % lit)
	_check("the flare settles into cruise", settled < 0.05, "flare=%.2f a second later" % settled)

	# --- a hit rings the airframe and a wounded one bleeds gas ---
	player.shield = 0.0
	player.take_damage(60.0, Vector2.RIGHT)
	var rung: float = player._shake
	var jolted := 0.0
	for i in 10:
		await physics_frame
		jolted = maxf(jolted, visuals.position.length())
	_check("a hit rings the airframe", rung > 0.5 and jolted > 1.0,
		"shake=%.2f swung %.1f px" % [rung, jolted])
	_check("a wounded hull bleeds gas", smoke.emitting, str(smoke.emitting))
	await _steps(60)
	_check("the ringing stops", player._shake < 0.02 and visuals.position.length() < 0.35,
		"shake=%.3f offset=%s" % [player._shake, str(visuals.position)])

	# --- custom actions are bound to WASD / Shift ---
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		var events := InputMap.action_get_events(action)
		var has_wasd := false
		for e in events:
			if e is InputEventKey and e.physical_keycode in [65, 68, 83, 87]:
				has_wasd = true
		_check("action bound: " + action, has_wasd, "%d events" % events.size())

	var boost_events := InputMap.action_get_events("boost")
	var has_shift := false
	for e in boost_events:
		if e is InputEventKey and e.physical_keycode == 4194325:
			has_shift = true
	_check("action bound: boost", has_shift, "%d events" % boost_events.size())

	print("RESULT: ", "FAILED" if _failed else "ALL PASS")
	quit(1 if _failed else 0)