extends SceneTree

## Headless contract for the unconnected UI foundation.
## Run: godot --headless --path . --script tests/ui_architecture_test.gd

const SCREENS := [
	"res://scenes/ui/core/InterfaceShell.tscn",
	"res://scenes/ui/screens/HUD.tscn",
	"res://scenes/ui/screens/HUDPreview.tscn",
	"res://scenes/ui/screens/ScannerScreen.tscn",
	"res://scenes/ui/screens/ScannerPreview.tscn",
	"res://scenes/ui/screens/ResearchScreen.tscn",
	"res://scenes/ui/screens/ResearchPreview.tscn",
	"res://scenes/ui/screens/EquipmentScreen.tscn",
	"res://scenes/ui/screens/UpgradesScreen.tscn",
	"res://scenes/ui/screens/UpgradesPreview.tscn",
	"res://scenes/ui/UpgradesConsole.tscn",
	"res://scenes/ui/screens/MainMenu.tscn",
	"res://scenes/ui/screens/PauseMenu.tscn",
]
const RESOLUTIONS := [
	Vector2i(640, 360),
	Vector2i(960, 540),
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1080),
	Vector2i(2560, 1440),
	Vector2i(1024, 768),
]

var _failed := 0
var _checked := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, condition: bool, detail: String = "") -> void:
	_checked += 1
	if condition:
		print("PASS  ", name, "  ", detail)
	else:
		_failed += 1
		print("FAIL  ", name, "  ", detail)


func _run() -> void:
	for path in SCREENS:
		var packed: PackedScene = load(path)
		_check("scene loads: %s" % path, packed != null)
		if packed == null:
			continue
		for resolution in RESOLUTIONS:
			await _check_resolution(path, packed, resolution)
	await _check_window_mode()

	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  ui_architecture  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _check_resolution(path: String, packed: PackedScene, resolution: Vector2i) -> void:
	var viewport := SubViewport.new()
	viewport.size = resolution
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport)
	var instance := packed.instantiate()
	viewport.add_child(instance)
	await process_frame
	await process_frame

	var viewport_rect := Rect2(Vector2.ZERO, Vector2(resolution))
	var outside := _find_outside(instance, viewport_rect)
	_check("%s @ %dx%d" % [path.get_file(), resolution.x, resolution.y],
		outside.is_empty(), "" if outside.is_empty() else outside)

	viewport.queue_free()
	await process_frame


func _find_outside(node: Node, viewport_rect: Rect2) -> String:
	if node is Control:
		var control := node as Control
		if control.visible and control.size > Vector2.ZERO:
			var rect := Rect2(control.global_position, control.size)
			if not viewport_rect.encloses(rect):
				return "%s rect=%s viewport=%s" % [control.get_path(), rect, viewport_rect]
	for child in node.get_children():
		# A ScrollContainer intentionally keeps a longer content strip outside
		# its viewport; the container clips it and exposes it through scrolling.
		if child is ScrollContainer:
			continue
		var result := _find_outside(child, viewport_rect)
		if not result.is_empty():
			return result
	return ""


func _check_window_mode() -> void:
	var initial_mode := DisplayServer.window_get_mode()
	var menu: Node = load("res://scenes/ui/screens/MainMenu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	var button := menu.get_node("SafeArea/Layout/Center/Panel/Content/DisplayMode")
	button.emit_signal("pressed")
	await process_frame
	var switched_mode := DisplayServer.window_get_mode()
	if DisplayServer.get_name() == "headless":
		_check("display mode API is available in headless", switched_mode == initial_mode,
			"mode=%d" % switched_mode)
	else:
		_check("display mode switches", switched_mode != initial_mode,
			"initial=%d switched=%d" % [initial_mode, switched_mode])
	button.emit_signal("pressed")
	await process_frame
	_check("display mode restores", DisplayServer.window_get_mode() == initial_mode,
		"restored=%d" % DisplayServer.window_get_mode())
	menu.queue_free()
	await process_frame
