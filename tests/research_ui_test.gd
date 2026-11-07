extends SceneTree

## Presentation-only research UI contract.
## Run: godot --headless --path . --script tests/research_ui_test.gd

const SCENE := "res://scenes/ui/screens/ResearchScreen.tscn"
const RESOLUTIONS := [
	Vector2i(640, 360), Vector2i(960, 540), Vector2i(1280, 720),
	Vector2i(1920, 1080), Vector2i(2560, 1080), Vector2i(1024, 768),
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
	await _check_states()
	await _check_markers_and_selection()
	await _check_results_and_xp()
	await _check_stress_content()
	await _check_animations()
	await _check_resolutions()
	await _check_no_gameplay_coupling()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  research_ui  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _make_screen() -> ResearchScreen:
	var screen := load(SCENE).instantiate() as ResearchScreen
	root.add_child(screen)
	return screen


func _panel(screen: ResearchScreen) -> ResearchPanel:
	return screen.get_node("SafeArea/Layout/Body/Panel") as ResearchPanel


func _check_states() -> void:
	var screen := _make_screen()
	await process_frame
	var panel := _panel(screen)
	var status := screen.get_node("SafeArea/Layout/Body/Panel/Content/StatusRow/Status") as Label
	var remaining := screen.get_node("SafeArea/Layout/Body/Panel/Content/StatusRow/Remaining") as Label
	var progress_text := screen.get_node("SafeArea/Layout/Body/Panel/Content/ProgressRow/ProgressText") as Label
	var action := screen.get_node("SafeArea/Layout/Body/Panel/Content/Action") as Button
	var registry := screen.get_node("SafeArea/Layout/Body/RegistryPanel/Content/Scroll/ObjectList") as VBoxContainer

	_check("registry is populated", registry.get_child_count() == 6,
		"count=%d" % registry.get_child_count())

	var expectations := [
		[ResearchObject.State.UNSTUDIED, "НЕ ИССЛЕДОВАН", false],
		[ResearchObject.State.AVAILABLE, "ИССЛЕДОВАНИЕ ДОСТУПНО", true],
		[ResearchObject.State.IN_PROGRESS, "АНАЛИЗ ВЫПОЛНЯЕТСЯ", true],
		[ResearchObject.State.PAUSED, "АНАЛИЗ ПРИОСТАНОВЛЕН", true],
		[ResearchObject.State.COMPLETED, "АНАЛИЗ ЗАВЕРШЁН", false],
		[ResearchObject.State.FULLY_STUDIED, "ПОЛНОСТЬЮ ИЗУЧЕН", false],
	]
	for expectation in expectations:
		var state: int = expectation[0]
		screen.set_demo_state(state)
		await process_frame
		var object := screen.current_object()
		_check("state %d is selected" % state, object != null and object.state == state,
			"" if object == null else object.status_text())
		_check("state %d status label" % state, status.text == expectation[1], status.text)
		var expected_action: bool = expectation[2]
		_check("state %d action availability" % state, action.disabled == (not expected_action),
			action.text)

	screen.set_demo_state(ResearchObject.State.IN_PROGRESS)
	await process_frame
	_check("running state shows remaining time", remaining.text.contains("00:37"), remaining.text)
	screen.set_demo_state(ResearchObject.State.PAUSED)
	await process_frame
	_check("paused state shows remaining time", remaining.text.contains("01:52"), remaining.text)
	screen.set_demo_state(ResearchObject.State.UNSTUDIED)
	await process_frame
	_check("unstudied state hides remaining time", remaining.text.contains("--:--"), remaining.text)

	screen.set_demo_state(ResearchObject.State.COMPLETED)
	await create_timer(0.7).timeout
	await process_frame
	_check("completed state reaches 100%", progress_text.text.contains("100%"), progress_text.text)
	screen.set_demo_state(ResearchObject.State.AVAILABLE)
	await create_timer(0.7).timeout
	await process_frame
	_check("available state starts at 0%", progress_text.text.contains("000%"), progress_text.text)

	panel.clear()
	_check("panel can be cleared", panel.get_node("Content/Placeholder").visible, "")
	screen.set_demo_state(ResearchObject.State.AVAILABLE)
	await process_frame
	_check("panel can be refilled", not panel.get_node("Content/Placeholder").visible, "")
	screen.queue_free()
	await process_frame



func _check_markers_and_selection() -> void:
	var screen := _make_screen()
	await process_frame
	var badges := {}
	for child in screen.get_node("SafeArea/Layout/Body/RegistryPanel/Content/Scroll/ObjectList").get_children():
		if child is ResearchObjectCard:
			badges[child.object_id] = child.get_node("Content/Info/BadgeRow/Badge").text
	_check("unknown object is marked", badges.get("SIG-4417", "").contains("НЕИЗВЕСТНЫЙ"), str(badges))
	_check("dangerous object is marked", badges.get("HAZ-77", "").contains("ОПАСНЫЙ"), str(badges))
	_check("rare object is marked", badges.get("ANO-003", "").contains("РЕДКИЙ"), str(badges))
	_check("new object is marked", badges.get("AST-044", "").contains("НОВЫЙ"), str(badges))

	screen.select_object("ANO-003")
	await process_frame
	var title := screen.get_node("SafeArea/Layout/Body/Panel/Content/Header/Info/Title") as Label
	var type_label := screen.get_node("SafeArea/Layout/Body/Panel/Content/Header/Info/Type") as Label
	var category := screen.get_node("SafeArea/Layout/Body/Panel/Content/Header/Info/Category") as Label
	var description := screen.get_node("SafeArea/Layout/Body/Panel/Content/Header/Info/Description") as Label
	var knowledge := screen.get_node("SafeArea/Layout/Body/Panel/Content/StatusRow/Knowledge") as Label
	_check("selected object shows its name", title.text.contains("РЕЗОНАНСНАЯ"), title.text)
	_check("selected object shows its type", type_label.text.contains("АНОМАЛИЯ"), type_label.text)
	_check("selected object shows its category", category.text.contains("РЕЗОНАНС"), category.text)
	_check("selected object shows a description", description.text.length() > 40, "")
	_check("selected object shows study level", knowledge.text.contains("3/5"), knowledge.text)
	screen.queue_free()
	await process_frame


func _check_results_and_xp() -> void:
	var screen := _make_screen()
	await process_frame
	screen.set_demo_state(ResearchObject.State.COMPLETED)
	await process_frame
	var results := screen.get_node("SafeArea/Layout/Body/Panel/Content/Results") as ResearchResults
	var xp := results.get_node("XpRow/XpValue") as Label
	var properties := results.get_node("Properties") as VBoxContainer
	var notification := results.get_node("NotificationPanel") as PanelContainer
	var notification_text := results.get_node("NotificationPanel/Content/Notification") as Label
	_check("research XP is shown", xp.text == "+300", xp.text)
	_check("discovered properties are listed", properties.get_child_count() == 3,
		"count=%d" % properties.get_child_count())
	_check("completion notification is shown", notification.visible, "")
	_check("completion notification has text", notification_text.text.contains("ЗАВЕРШЁН"), notification_text.text)

	screen.set_demo_state(ResearchObject.State.AVAILABLE)
	await process_frame
	var xp_available := results.get_node("XpRow/XpValue") as Label
	var properties_available := results.get_node("Properties") as VBoxContainer
	_check("no XP before analysis", xp_available.text == "+0", xp_available.text)
	_check("no properties before analysis", properties_available.get_child_count() == 0,
		"count=%d" % properties_available.get_child_count())
	_check("no completion notice before analysis", not notification.visible, "")
	screen.queue_free()
	await process_frame


func _check_stress_content() -> void:
	var screen := _make_screen()
	await process_frame
	screen.set_demo_state(ResearchObject.State.AVAILABLE, ResearchDemoData.stress_objects(24))
	await process_frame
	await process_frame
	var list := screen.get_node("SafeArea/Layout/Body/RegistryPanel/Content/Scroll/ObjectList") as VBoxContainer
	var scroll := list.get_parent() as ScrollContainer
	_check("large registry is populated", list.get_child_count() == 24,
		"count=%d" % list.get_child_count())
	_check("large registry scrolls", scroll.get_v_scroll_bar().max_value > 0.0,
		"max=%f" % scroll.get_v_scroll_bar().max_value)
	_check("long titles stay clipped on cards",
		list.get_child(0).get_node("Content/Info/TitleRow/Title").text.length() > 60, "")

	screen.select_object("STRESS-004")
	await create_timer(0.7).timeout
	await process_frame
	var panel := _panel(screen)
	var results := panel.get_node("Content/Results") as ResearchResults
	var xp := results.get_node("XpRow/XpValue") as Label
	_check("large XP value is rendered", xp.text == "+1250000", xp.text)
	var progress_text := panel.get_node("Content/ProgressRow/ProgressText") as Label
	_check("large progress is clamped", progress_text.text.contains("100%"), progress_text.text)

	screen.select_object("STRESS-002")
	await process_frame
	var remaining := panel.get_node("Content/StatusRow/Remaining") as Label
	_check("long remaining time is formatted", remaining.text.contains("61:01"), remaining.text)
	screen.queue_free()
	await process_frame



func _check_animations() -> void:
	var screen := _make_screen()
	await process_frame
	var panel := _panel(screen)
	screen.select_object("ANO-003")
	await process_frame
	var progress := panel.get_node("Content/ProgressRow/Progress") as ProgressBar
	_check("progress is animated, not snapped", progress.value < 100.0,
		"value=%f" % progress.value)
	await create_timer(1.5).timeout
	await process_frame
	_check("progress reaches its target", progress.value >= 99.9,
		"value=%f" % progress.value)

	var results := panel.get_node("Content/Results") as ResearchResults
	var properties := results.get_node("Properties") as VBoxContainer
	var rows_faded := true
	for child in properties.get_children():
		var control := child as Control
		if control != null and control.modulate.a < 0.99:
			rows_faded = false
	_check("revealed properties fade in", rows_faded, "")
	screen.queue_free()
	await process_frame


func _check_resolutions() -> void:
	for resolution in RESOLUTIONS:
		var viewport := SubViewport.new()
		viewport.size = resolution
		root.add_child(viewport)
		var screen := load(SCENE).instantiate() as Control
		viewport.add_child(screen)
		await process_frame
		await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(resolution))
		var visible := _visible_controls_inside(screen, bounds)
		_check("research @ %dx%d stays readable" % [resolution.x, resolution.y],
			visible.is_empty(), visible)
		viewport.queue_free()
		await process_frame


func _visible_controls_inside(node: Node, bounds: Rect2) -> String:
	for child in node.get_children():
		if child is ScrollContainer:
			continue
		if child is Control:
			var control := child as Control
			if control.visible and control.size > Vector2.ZERO:
				var rect := Rect2(control.global_position, control.size)
				if not bounds.encloses(rect):
					return "%s rect=%s" % [control.get_path(), rect]
		var result := _visible_controls_inside(child, bounds)
		if not result.is_empty():
			return result
	return ""


func _check_no_gameplay_coupling() -> void:
	var screen := _make_screen()
	await process_frame
	var requested := [false]
	var paused := [false]
	screen.research_requested.connect(func(_object_id: String) -> void: requested[0] = true)
	screen.research_pause_requested.connect(func(_object_id: String) -> void: paused[0] = true)
	var panel := _panel(screen)
	screen.set_demo_state(ResearchObject.State.AVAILABLE)
	await process_frame
	(panel.get_node("Content/Action") as Button).emit_signal("pressed")
	_check("action only emits a UI request", requested[0], "")
	screen.set_demo_state(ResearchObject.State.IN_PROGRESS)
	await process_frame
	(panel.get_node("Content/Action") as Button).emit_signal("pressed")
	_check("pause action only emits a UI request", paused[0], "")

	var source := FileAccess.get_file_as_string("res://ui/research/research_screen.gd")
	var panel_source := FileAccess.get_file_as_string("res://ui/research/research_panel.gd")
	var forbidden := ["res://scripts/research", "ResearchSystem.", "ResearchSystem("]
	var coupled := false
	for marker in forbidden:
		if source.contains(marker) or panel_source.contains(marker):
			coupled = true
	_check("research UI is not coupled to the research system", not coupled, "")
	screen.queue_free()
	await process_frame
