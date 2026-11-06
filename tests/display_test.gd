extends SceneTree

## The glass and the world have to answer the window, not the 960x540 frame the
## game was authored in. With `canvas_items` stretch and aspect `expand` a window
## that is not 16:9 shows more space on one axis instead of black bars, the
## scale stays uniform so no sprite is squashed, and the HUD keeps its distance
## from the corner it hugs.
## Run: godot --headless --path . --script tests/display_test.gd

const DESIGN := Vector2(960.0, 540.0)

## The modes a player actually lands on: three 16:9, one 21:9, one 16:10 and one
## 5:4. The first two need no extra space, the 21:9 needs width, the last one
## needs height - between them they cover both expansion axes.
const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3440, 1440),
	Vector2i(1920, 1200),
	Vector2i(1280, 1024),
]

var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("PASS  ", name, "  ", detail)
	else:
		_failed += 1
		print("FAIL  ", name, "  ", detail)


func _run() -> void:
	var mode := str(ProjectSettings.get_setting("display/window/stretch/mode"))
	var aspect := str(ProjectSettings.get_setting("display/window/stretch/aspect"))
	_check("stretch keeps the authored scale", mode == "canvas_items", mode)
	_check("a window that is not 16:9 shows more space instead of bars",
		aspect == "expand", aspect)
	var width := int(ProjectSettings.get_setting("display/window/size/viewport_width"))
	var height := int(ProjectSettings.get_setting("display/window/size/viewport_height"))
	_check("the authored frame is 960x540", width == 960 and height == 540,
		"%dx%d" % [width, height])

	root.size = Vector2i(960, 540)
	var scene: Node = load("res://scenes/world/SpaceMap.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var hud: Control = scene.get_node("HUD/Root")
	var bg: Node = scene.get_node("Background")
	var cam: Camera2D = scene.get_node("Ship/Camera")

	for res in RESOLUTIONS:
		await _verify_window(res, hud, bg, cam)

	# Back to the authored frame: nothing may keep an offset it picked up while
	# the window was wider or taller.
	root.size = Vector2i(960, 540)
	await process_frame
	await process_frame
	var restored: Dictionary = hud.hud_metrics()
	_check("back in the authored frame the glass sits where it was drawn",
		(restored["extra"] as Vector2) == Vector2.ZERO, str(restored["extra"]))

	scene.queue_free()
	await process_frame
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  display")
	quit(1 if _failed > 0 else 0)


## Resize the window and check the two things stretch owns: the canvas reaches
## every edge at one uniform scale, and the corner readouts followed their
## corners. The background is measured in world pixels, zoom included, because
## that is the area it has to cover.
func _verify_window(res: Vector2i, hud: Control, bg: Node, cam: Camera2D) -> void:
	root.size = res
	await process_frame
	await process_frame

	var tag := "%dx%d" % [res.x, res.y]
	var window := Vector2(res)
	var want_scale := minf(window.x / DESIGN.x, window.y / DESIGN.y)
	var visible := root.get_visible_rect().size
	var wanted := window / want_scale
	var scale := root.get_final_transform().get_scale()

	# With aspect `keep` the canvas would stay 960x540 here and the short axis
	# would be padded with bars; `expand` means the canvas is exactly the window
	# divided by the uniform scale.
	_check(tag + ": the canvas fills the window",
		visible.is_equal_approx(wanted),
		"canvas=%s expected=%s" % [str(visible), str(wanted)])
	_check(tag + ": the image is not stretched",
		is_equal_approx(scale.x, scale.y) and is_equal_approx(scale.x, want_scale),
		"scale=%s expected=%.3f" % [str(scale), want_scale])

	var metrics: Dictionary = hud.hud_metrics()
	_check(tag + ": the HUD root covers the canvas",
		(metrics["viewport"] as Vector2).is_equal_approx(visible),
		str(metrics["viewport"]))

	var radar: Vector2 = metrics["radar_center"]
	var design_radar := Vector2(hud.radar_center)
	var radar_right := DESIGN.x - design_radar.x
	var radar_top := design_radar.y
	_check(tag + ": the radar keeps its top-right margin",
		is_equal_approx(visible.x - radar.x, radar_right) and is_equal_approx(radar.y, radar_top),
		"radar=%s" % str(radar))

	# The telemetry block has no fixed height - it grows with what the hull can
	# report - so the only safe anchor is its last baseline above the bottom edge.
	var tele: Vector2 = metrics["telemetry_origin"]
	var tele_bottom := float(metrics["telemetry_bottom"])
	_check(tag + ": the telemetry block fits inside the bottom edge",
		tele.y > 0.0 and tele_bottom <= visible.y - 4.0,
		"origin=%s bottom=%.1f" % [str(tele), tele_bottom])

	# The labels and the scanner prompt are anchored Controls, so the engine
	# moves them; what matters is that the move keeps them inside the canvas.
	var on_screen := Rect2(Vector2.ZERO, visible)
	for node_name in ["MissionTitle", "Objective1", "Objective2", "Objective3", "Scanner"]:
		var control := hud.get_node(node_name) as Control
		var box := control.get_global_rect()
		_check(tag + ": " + node_name + " stays on screen", on_screen.encloses(box),
			str(box))

	var world := visible / cam.zoom
	var covered: Rect2 = bg.call("_visible_rect_local")
	_check(tag + ": the parallax covers the whole view",
		covered.size.x >= world.x - 1.0 and covered.size.y >= world.y - 1.0,
		"bg=%s view=%s" % [str(covered.size), str(world)])