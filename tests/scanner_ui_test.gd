extends SceneTree

## Presentation-only scanner UI contract.
## Run: godot --headless --path . --script tests/scanner_ui_test.gd

const SCENE := "res://scenes/ui/screens/ScannerScreen.tscn"
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
	await _check_stress_list()
	await _check_resolutions()
	await _check_window_modes()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  scanner_ui  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _make_screen() -> ScannerScreen:
	var screen := load(SCENE).instantiate() as ScannerScreen
	root.add_child(screen)
	return screen


func _check_states() -> void:
	var screen := _make_screen()
	await process_frame
	var state := screen.get_node("SafeArea/Layout/Header/State") as Label
	var readiness := screen.get_node("SafeArea/Layout/Device/Content/Top/Readiness") as Label
	var progress := screen.get_node("SafeArea/Layout/Device/Content/ProgressRow/Progress") as ProgressBar
	var remaining := screen.get_node("SafeArea/Layout/Device/Content/Top/Remaining") as Label
	var action := screen.get_node("SafeArea/Layout/Footer/Action") as Button

	screen.set_demo_state(ScannerScreen.DemoState.READY, [])
	_check("ready state", state.text.contains("ГОТОВ") and readiness.text.contains("100%") and not action.disabled, state.text)
	screen.set_demo_state(ScannerScreen.DemoState.SCANNING, ScannerDemoData.contacts())
	_check("scanning state", state.text.contains("СКАНИРОВАНИЕ") and progress.value == 63.0 and remaining.text.contains("00:37") and action.disabled, state.text)
	screen.set_demo_state(ScannerScreen.DemoState.CONTACTS_FOUND, ScannerDemoData.contacts())
	_check("contacts found state", state.text.contains("КОНТАКТЫ") and progress.value == 100.0, state.text)
	screen.set_demo_state(ScannerScreen.DemoState.NO_CONTACTS, [])
	_check("empty state", state.text.contains("КОНТАКТОВ НЕТ") and progress.value == 100.0, state.text)
	screen.set_demo_state(ScannerScreen.DemoState.LOW_ENERGY, [])
	_check("low energy state", state.text.contains("ЭНЕРГИИ") and action.disabled, state.text)
	screen.set_demo_state(ScannerScreen.DemoState.MALFUNCTION, [])
	_check("malfunction state", state.text.contains("НЕИСПРАВНОСТЬ") and action.disabled, state.text)
	screen.queue_free()
	await process_frame


func _check_markers_and_selection() -> void:
	var screen := _make_screen()
	await process_frame
	screen.set_demo_state(ScannerScreen.DemoState.CONTACTS_FOUND, ScannerDemoData.contacts())
	await process_frame
	var scope := screen.get_node("SafeArea/Layout/Main/ScopePanel/Content/Scope") as ScannerScope
	var kinds := {}
	for child in scope.get_children():
		if child is ScannerMarker:
			kinds[child.marker_kind] = true
	_check("all contact marker kinds are visible", kinds.size() == 5, str(kinds.keys()))
	screen.select_contact("ANO-003")
	await process_frame
	var detail := screen.get_node("SafeArea/Layout/Detail") as PanelContainer
	var title := screen.get_node("SafeArea/Layout/Detail/Content/Kind/DetailTitle") as Label
	var analysis := screen.get_node("SafeArea/Layout/Detail/Content/Analysis/DetailAnalysis") as Label
	_check("anomaly detail is selected", detail.visible and title.text.contains("АНОМАЛИЯ"), title.text)
	_check("anomaly analysis availability is explicit", analysis.text.contains("НЕДОСТУПЕН"), analysis.text)
	screen.queue_free()
	await process_frame


func _check_stress_list() -> void:
	var screen := _make_screen()
	await process_frame
	screen.set_demo_state(ScannerScreen.DemoState.CONTACTS_FOUND, ScannerDemoData.stress_contacts(28))
	await process_frame
	var list := screen.get_node("SafeArea/Layout/Main/ContactsPanel/Content/Scroll/ContactList") as VBoxContainer
	var scroll := list.get_parent() as ScrollContainer
	_check("large contact list is populated", list.get_child_count() == 28, "count=%d" % list.get_child_count())
	_check("large contact list scrolls", scroll.get_v_scroll_bar().max_value > 0.0, "max=%f" % scroll.get_v_scroll_bar().max_value)
	_check("long titles stay on cards", list.get_child(0).get_node("Content/Info/TitleRow/Title").text.length() > 60, "")
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
		_check("scanner @ %dx%d stays readable" % [resolution.x, resolution.y], visible.is_empty(), visible)
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


func _check_window_modes() -> void:
	var initial := DisplayServer.window_get_mode()
	var screen := _make_screen()
	await process_frame
	var action := screen.get_node("SafeArea/Layout/Footer/Action") as Button
	_check("visual action button is focusable", action.focus_mode == Control.FOCUS_ALL, "")
	var requested := [false]
	screen.scan_requested.connect(func() -> void: requested[0] = true)
	action.emit_signal("pressed")
	_check("visual action only emits a UI request", requested[0], "")
	screen.queue_free()
	await process_frame
	_check("display mode remains available", DisplayServer.window_get_mode() == initial, "mode=%d" % DisplayServer.window_get_mode())
