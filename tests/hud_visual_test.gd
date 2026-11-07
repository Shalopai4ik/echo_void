extends SceneTree

## Visual-only HUD contract. It verifies responsive bounds, protected central
## gameplay space and the presence of normal/damage/critical presentations.
## Run: godot --headless --path . --script tests/hud_visual_test.gd

const HUD_SCENE := "res://scenes/ui/screens/HUD.tscn"
const RESOLUTIONS := [
	Vector2i(640, 360),
	Vector2i(960, 540),
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1080),
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
	for resolution in RESOLUTIONS:
		await _check_resolution(resolution)
	await _check_visual_states()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  hud_visual  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _check_resolution(resolution: Vector2i) -> void:
	var viewport := SubViewport.new()
	viewport.size = resolution
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport)
	var hud: Control = load(HUD_SCENE).instantiate()
	viewport.add_child(hud)
	await process_frame
	await process_frame

	var status := hud.get_node("SafeArea/Layout/BottomRow/ShipStatus") as Control
	var notifications := hud.get_node("SafeArea/Layout/BottomRow/Notifications") as Control
	var safe_rect := Rect2(Vector2(8, 8), Vector2(resolution) - Vector2(16, 16))
	var resolution_vector := Vector2(resolution)
	var protected_center := Rect2(resolution_vector * Vector2(0.45, 0.18), resolution_vector * Vector2(0.10, 0.48))
	var status_rect := Rect2(status.global_position, status.size)
	var notifications_rect := Rect2(notifications.global_position, notifications.size)
	var detail := "status=%s notifications=%s" % [status_rect, notifications_rect]

	_check("HUD @ %dx%d inside safe area" % [resolution.x, resolution.y],
		safe_rect.encloses(status_rect) and safe_rect.encloses(notifications_rect), detail)
	_check("HUD @ %dx%d protects center" % [resolution.x, resolution.y],
		not status_rect.intersects(protected_center) and not notifications_rect.intersects(protected_center),
		"center=%s" % protected_center)
	_check("HUD @ %dx%d keeps panels readable" % [resolution.x, resolution.y],
		status.size.x >= 228.0 and notifications.size.x >= 218.0, detail)

	viewport.queue_free()
	await process_frame


func _check_visual_states() -> void:
	var panel: ShipStatusPanel = load("res://scenes/ui/components/ShipStatusPanel.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	var status_label := panel.get_node("Content/Header/Status") as Label
	panel.set_state("НОРМА")
	var normal := status_label.get_theme_color("font_color")
	panel.set_state("ПОВРЕЖДЕНИЕ")
	var damaged := status_label.get_theme_color("font_color")
	panel.set_state("КРИТИЧЕСКОЕ")
	var critical := status_label.get_theme_color("font_color")
	_check("ship status exposes three visual states",
		normal != damaged and damaged != critical and normal != critical,
		"normal=%s damaged=%s critical=%s" % [normal, damaged, critical])
	panel.queue_free()
	await process_frame
