extends SceneTree

## Renders idle / cruise / boost frames for visual review.
## Run: godot --path . --script tests/screenshot.gd

const OUT := "res://test-output/game/"

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")

func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)

	await process_frame
	await physics_frame
	await _save("shot-idle.png")

	Input.action_press("move_right")
	for i in 25:
		await physics_frame
	await _save("shot-cruise.png")

	Input.action_press("boost")
	for i in 25:
		await physics_frame
	await _save("shot-boost.png")

	Input.action_release("boost")
	Input.action_release("move_right")
	quit()

func _save(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	image.save_png(OUT + file)
	print("saved ", OUT + file, " ", image.get_size())