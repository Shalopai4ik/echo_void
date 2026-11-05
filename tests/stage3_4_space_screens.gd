extends SceneTree

## Renders sub-stage 3.4 space objects for a human look.
## Run: godot --path . --script tests/stage3_4_space_screens.gd --rendering-driver opengl3

const OUT := "res://test-output/stage34/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	var ship := map.get_node("Ship") as ShipController
	var cam := ship.get_node("Camera") as Camera2D
	var field := map.get_node("Field") as EchoWorldField
	for i in 90:
		await physics_frame
	await _save("01_space_objects")

	# Search deterministic windows for a live debris body, then frame it.
	var found := false
	for at in [Vector2(9000, 5000), Vector2(-14000, 8000), Vector2(26000, -17000),
			Vector2(-31000, -24000), Vector2(41000, 9000), Vector2(-47000, 31000)]:
		ship.global_position = at
		ship.linear_velocity = Vector2.ZERO
		cam.snap()
		for i in 90:
			await physics_frame
		for body in field.bodies_of("debris"):
			found = true
			ship.global_position = body.global_position + Vector2(150, 80)
			break
		if found:
			break
	cam.snap()
	for i in 20:
		await physics_frame
	await _save("02_debris")
	print("debris visible: ", found)
	quit(0 if found else 2)


func _save(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	image.save_png(OUT + file + ".png")
	print("saved ", OUT + file + ".png ", image.get_size())
