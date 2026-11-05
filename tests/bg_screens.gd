extends SceneTree

## Renders the background test scene from several viewpoints for review.
## Run: godot --path . --script tests/bg_screens.gd --rendering-driver opengl3

const OUT := "res://test-output/bg/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://scenes/space_bg_test.tscn").instantiate()
	root.add_child(scene)
	await process_frame

	var ship: Node2D = scene.get_node("Ship")
	var bg: Node = scene.get_node("Background")
	bg.print_report_on_ready = true

	var shots := {
		"home": Vector2(480, 270),
		"far_right": Vector2(120000, 300),
		"far_left": Vector2(-90000, -400),
		"deep_down": Vector2(500, 260000),
		"diagonal": Vector2(-340000, -190000),
		"seed_b": Vector2(120000, 300),
	}
	for name in shots:
		ship.position = shots[name]
		if name == "seed_b":
			bg.set_seed(31337)
		await _settle()
		await _save("bg_" + name + ".png")

	# pixel-level determinism: same seed and same place must be the same frame,
	# a different seed at the same place must be a different frame
	ship.position = Vector2(60000, 20000)
	bg.set_seed(20261029)
	await _settle()
	var a := _grab()
	bg.set_seed(20261029)
	await _settle()
	var b := _grab()
	bg.set_seed(987654)
	await _settle()
	var c := _grab()
	print("same seed identical=", _maxdiff(a, b), "  other seed differs=", _maxdiff(a, c))
	bg.set_seed(20261029)

	# a dense action shot: fly right at boost speed for a few seconds
	bg.set_seed(20261029)
	ship.position = Vector2(480, 270)
	Input.action_press("move_right")
	Input.action_press("boost")
	for i in 180:
		await physics_frame
	Input.action_release("move_right")
	Input.action_release("boost")
	await _settle()
	await _save("bg_boost_flight.png")
	print("stats ", bg.stats())
	quit()


func _settle() -> void:
	for i in 24:
		await process_frame
	await RenderingServer.frame_post_draw


func _grab() -> Image:
	return root.get_texture().get_image()


func _maxdiff(a: Image, b: Image) -> float:
	var m := 0.0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			m = maxf(m, absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b))
	return m


func _save(file: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT + file)
	print("saved ", file, " ", img.get_size(), " mean=", _mean(img))


func _mean(img: Image) -> String:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for y in range(0, img.get_height(), 7):
		for x in range(0, img.get_width(), 7):
			var c := img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
	var n := float(img.get_height() / 7) * float(img.get_width() / 7)
	return "%.3f/%.3f/%.3f" % [r / n, g / n, b / n]
