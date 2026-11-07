extends SceneTree

## Renders scanner UI screenshots for visual review.
## Run: godot --path . --script tests/scanner_ui_visual.gd

const OUT := "res://test-output/scanner-ui/"

var _failed := 0
var _checked := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var scene: Control = load("res://scenes/ui/screens/ScannerPreview.tscn").instantiate() as Control
	root.add_child(scene)
	await _settle()
	var screen := scene.get_node("ScannerScreen")
	for path in ["SafeArea/Layout/Header", "SafeArea/Layout/Header/Title", "SafeArea/Layout/Header/State", "SafeArea/Layout/Detail", "SafeArea/Layout/Detail/Content/Kind/DetailTitle", "SafeArea/Layout/Detail/Content/Description/DetailDescription", "SafeArea/Layout/Main/ScopePanel/Content/Legend"]:
		var control := screen.get_node(path) as Control
		print(path, " rect=", control.get_global_rect(), " text=", (control as Label).text if control is Label else "")
	_check("scanner header and detail remain visible", (screen.get_node("SafeArea/Layout/Header/Title") as Label).visible and (screen.get_node("SafeArea/Layout/Detail/Content/Kind/DetailTitle") as Label).visible)
	await _save("scanner_windowed_960x540.png")

	root.size = Vector2i(1280, 720)
	await _settle()
	await _save("scanner_windowed_1280x720.png")

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	await _settle()
	await _save("scanner_fullscreen.png")
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  scanner_ui_visual  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _check(name: String, condition: bool, detail: String = "") -> void:
	_checked += 1
	if condition:
		print("PASS  ", name, "  ", detail)
	else:
		_failed += 1
		print("FAIL  ", name, "  ", detail)


func _settle() -> void:
	for index in 12:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(file_name: String) -> void:
	var image := root.get_texture().get_image()
	image.save_png(OUT + file_name)
	print("saved ", OUT + file_name, " ", image.get_size())
