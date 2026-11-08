extends SceneTree
## Uncapped FPS of the flight scene with layers toggled (vsync off, GPU at full clock).
func _initialize() -> void:
	call_deferred("_run")
func _fps(label: String, seconds := 3.0) -> void:
	for i in 20:
		await process_frame
	var t0 := Time.get_ticks_usec(); var n := 0
	while Time.get_ticks_usec() - t0 < int(seconds * 1000000):
		await process_frame
		n += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / n
	print("%-36s %6.2f ms/frame  (%5.0f fps)" % [label, ms, 1000.0 / ms])
func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var map: Node = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	map.get_node("Ship").global_position = Vector2(8000, -6000)
	for i in 120:
		await process_frame
	await _fps("all")
	for p in ["HUD"]:
		var n = map.get_node(p)
		n.visible = false
		await _fps("without " + p)
		n.visible = true
	await _fps("all again")
	quit(0)
