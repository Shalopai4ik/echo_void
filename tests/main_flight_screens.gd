extends SceneTree

## Captures the real game scene while flying, to confirm the camera keeps the
## ship framed and the parallax world keeps streaming past it.
## Run: godot --path . --script tests/main_flight_screens.gd --rendering-driver opengl3

const OUT := "res://test-output/game/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: Node2D = scene.get_node("Player")
	var cam: Camera2D = player.get_node("Camera2D")
	var bg: Node = scene.get_node("Background")
	await _settle()
	await _save("01_start")

	Input.action_press("move_right")
	Input.action_press("boost")
	for i in 240:
		await physics_frame
	Input.action_release("boost")
	await _settle()
	await _save("02_cruise_right")

	Input.action_press("move_up")
	for i in 150:
		await physics_frame
	Input.action_release("move_right")
	Input.action_release("move_up")
	await _settle()
	await _save("03_turn_up")
	_check(player, cam, bg)

	# a long unbounded run: nothing may run out or pile up
	for i in 1800:
		Input.action_press("move_right")
		await physics_frame
	Input.action_release("move_right")
	await _settle()
	await _save("04_after_long_flight")
	_check(player, cam, bg)
	var field: EchoAsteroidField = scene.get_node("Asteroids")
	_expect("belt still streaming after 30 s of flight",
		field.rock_count() > 3 and field.rock_count() <= field.max_rocks,
		"%d/%d rocks" % [field.rock_count(), field.max_rocks])
	var st: Dictionary = bg.stats()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  pos=", player.position, "  bg=", st)
	scene.queue_free()
	await _settle()
	quit(1 if _failed > 0 else 0)


var _failed := 0


func _check(player: Node2D, cam: Camera2D, bg: Node) -> void:
	var gap: float = cam.global_position.distance_to(player.global_position)
	_expect("ship framed by camera", gap < 24.0, "gap=%.1f pos=%s" % [gap, str(player.position)])
	var st: Dictionary = bg.stats()
	_expect("world still populated", int(st.nodes) > 20, str(st))


func _expect(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + "   " + detail)
	if not ok:
		_failed += 1


func _settle() -> void:
	for i in 20:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(tag: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT + tag + ".png")
	print("  saved ", tag, " ", img.get_size())
