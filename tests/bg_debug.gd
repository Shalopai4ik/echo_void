extends SceneTree

## Diagnostic render: each band alone, plus boosted composites.
## Toggles the layer nodes directly so the result cannot be confused with the
## export-flag plumbing.
## Run: godot --path . --script tests/bg_debug.gd --rendering-driver opengl3

const OUT := "res://screenshots/bg/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://scenes/space_bg_test.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var ship: Node2D = scene.get_node("Ship")
	var bg: Node = scene.get_node("Background")
	ship.position = Vector2(480, 270)
	bg.nebula_breathing = 0.0
	await _settle()

	var layers: Array = []
	for child in bg.get_children():
		if child is EchoSpaceLayer:
			layers.append(child)
	var names: Array[String] = []
	for l in layers:
		names.append(l.name)
	print("bands found: ", ", ".join(names))

	for l in layers:
		for o in layers:
			o.visible = (o == l)
		await _settle()
		var live := 0
		for o in layers:
			if o.visible:
				live = o.live_nodes()
		await _save("dbg_only_" + String(l.name) + ".png")
		print("     nodes=", live)

	for l in layers:
		l.visible = true
	bg.exposure = 3.0
	await _settle()
	await _save("dbg_all_boost3.png")
	bg.exposure = 1.0
	await _settle()
	await _save("dbg_all_normal.png")
	scene.queue_free()
	await _settle()
	# The diagnostic has to end by itself: a script that only writes its frames and
	# then keeps the process alive leaves a headless run hanging with nothing to
	# wait for.
	quit()


func _settle() -> void:
	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(file: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT + file)
	var mx := 0.0
	var sum := 0.0
	var lit := 0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			var v: float = maxf(c.r, maxf(c.g, c.b))
			sum += v
			n += 1
			mx = maxf(mx, v)
			if v > 0.06:
				lit += 1
	print("  ", file, " mean=%.4f max=%.3f lit=%.1f%%" % [sum / n, mx, 100.0 * lit / n])
