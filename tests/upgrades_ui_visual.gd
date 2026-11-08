extends SceneTree

## Renders upgrades panel screenshots for visual review.
## Run: godot --path . --script tests/upgrades_ui_visual.gd

const OUT := "res://test-output/upgrades-ui/"

var _failed := 0
var _checked := 0
var _screen: UpgradesScreen


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _run() -> void:
	var scene: Control = load("res://scenes/ui/screens/UpgradesPreview.tscn").instantiate() as Control
	root.add_child(scene)
	_screen = scene.get_node("UpgradesScreen") as UpgradesScreen
	await _settle()
	_check("panel is open", _screen.is_open())
	_check("every device is listed", _screen.get_node(
		"SafeArea/Layout/Body/DevicePanel/Content/Scroll/DeviceList").get_child_count() == 3)
	_check("detail follows the selection", _device_name() == "СКАНЕР ОБЗОРА", _device_name())
	await _save("upgrades_windowed_960x540.png")

	_screen.select_device("signal_light")
	await _settle()
	_check("device switch repaints the detail", _device_name() == "СИГНАЛЬНЫЕ ОГНИ", _device_name())
	await _save("upgrades_signal_light_960x540.png")

	_screen.select_device("scanner")
	_screen.add_xp(150)
	await _settle()
	await _save("upgrades_xp_gain_960x540.png")

	root.size = Vector2i(1280, 720)
	await _settle()
	await _save("upgrades_windowed_1280x720.png")

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	await _settle()
	_check("panel is open in fullscreen", _screen.is_open())
	await _save("upgrades_fullscreen.png")
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	await _settle()

	_screen.close()
	await _settle()
	_check("close hides the panel", not _screen.is_open())
	await _save("upgrades_closed.png")

	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  upgrades_ui_visual  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _device_name() -> String:
	var label := _screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/DetailHeader/Info/DeviceName") as Label
	return label.text


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