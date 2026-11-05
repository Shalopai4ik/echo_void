extends SceneTree

## Renders the chunk overlay for a human look, with and without it raised.
## Run: godot --path . --script tests/stage3_3_chunk_screens.gd --rendering-driver opengl3
##
## The headless suite checks that the overlay is down by default; only a picture
## can say whether the borders land on the chunks and whether the panel is legible.

const OUT := "res://test-output/stage33/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	var ship := map.get_node("Ship") as ShipController
	var cam := ship.get_node("Camera") as Camera2D
	for i in 90:
		await physics_frame

	await _save("01_overlay_off")
	ship.show_debug = true
	for i in 8:
		await physics_frame
	await _save("02_overlay_on")

	# somewhere with a denser belt, so the borders have something to describe
	ship.global_position = Vector2(12000, -9000)
	ship.linear_velocity = Vector2.ZERO
	cam.snap()
	for i in 90:
		await physics_frame
	await _save("03_overlay_far")

	ship.show_debug = false
	for i in 4:
		await physics_frame
	await _save("04_overlay_hidden")
	quit()


func _save(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	image.save_png(OUT + file + ".png")
	print("saved ", OUT + file + ".png ", image.get_size())