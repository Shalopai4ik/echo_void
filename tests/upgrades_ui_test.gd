extends SceneTree

## Headless contract for the presentation-only upgrades panel.
## Run: godot --headless --path . --script tests/upgrades_ui_test.gd

const SCENE := "res://scenes/ui/screens/UpgradesScreen.tscn"
const RESOLUTIONS := [
	Vector2i(640, 360), Vector2i(960, 540), Vector2i(1280, 720),
	Vector2i(1920, 1080), Vector2i(2560, 1080), Vector2i(1024, 768),
]
const UI_SOURCES := [
	"res://ui/upgrades/upgrades_screen.gd",
	"res://ui/upgrades/upgrade_device_card.gd",
	"res://ui/upgrades/upgrade_path_row.gd",
	"res://ui/upgrades/research_xp_badge.gd",
	"res://ui/upgrades/upgrade_device.gd",
	"res://ui/upgrades/upgrade_visual.gd",
	"res://ui/upgrades/upgrades_presentation.gd",
	"res://ui/upgrades/upgrades_demo_data.gd",
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
	await _check_open_close()
	await _check_devices()
	await _check_paths()
	await _check_action_is_a_request()
	await _check_maxed_path()
	await _check_xp_gain()
	await _check_resolutions()
	await _check_empty_catalogue()
	await _check_readout_on_hud()
	await _check_no_gameplay_coupling()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS",
		"  upgrades_ui  checks=%d failed=%d" % [_checked, _failed])
	quit(1 if _failed > 0 else 0)


func _make_screen() -> UpgradesScreen:
	var screen := load(SCENE).instantiate() as UpgradesScreen
	root.add_child(screen)
	return screen


func _cards(screen: UpgradesScreen) -> VBoxContainer:
	return screen.get_node(
		"SafeArea/Layout/Body/DevicePanel/Content/Scroll/DeviceList") as VBoxContainer


func _rows(screen: UpgradesScreen) -> VBoxContainer:
	return screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/PathList") as VBoxContainer


func _device_name(screen: UpgradesScreen) -> Label:
	return screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/DetailHeader/Info/DeviceName") as Label


func _device_level(screen: UpgradesScreen) -> Label:
	return screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/DetailHeader/Info/DeviceLevel") as Label


func _selected_info(screen: UpgradesScreen) -> Label:
	return screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/SelectedPanel/SelectedInfo") as Label


func _action(screen: UpgradesScreen) -> Button:
	return screen.get_node("SafeArea/Layout/Footer/Action") as Button


func _badge_value(screen: UpgradesScreen) -> Label:
	return screen.get_node(
		"SafeArea/Layout/Header/XpBadge/Content/Text/Value") as Label


func _badge_delta(screen: UpgradesScreen) -> Label:
	return screen.get_node("SafeArea/Layout/Header/XpBadge/Content/Delta") as Label


func _check_open_close() -> void:
	var screen := _make_screen()
	await process_frame
	var events := [0, 0]
	screen.opened.connect(func() -> void: events[0] += 1)
	screen.closed.connect(func() -> void: events[1] += 1)
	_check("panel opens on start", screen.is_open(), "")
	screen.close()
	await process_frame
	_check("close hides the panel", not screen.is_open(), "")
	_check("close emits its signal", events[1] == 1, "")
	_check("hidden panel keeps its content", _cards(screen).get_child_count() == 4,
		"cards=%d" % _cards(screen).get_child_count())
	screen.open()
	await process_frame
	_check("open shows the panel", screen.is_open(), "")
	_check("open emits its signal", events[0] == 1, "")
	screen.toggle()
	await process_frame
	_check("toggle closes an open panel", not screen.is_open(), "")
	screen.toggle()
	await process_frame
	_check("toggle opens a closed panel", screen.is_open(), "")
	screen.queue_free()
	await process_frame


func _check_devices() -> void:
	var screen := _make_screen()
	await process_frame
	var cards := _cards(screen)
	var count := screen.get_node(
		"SafeArea/Layout/Body/DevicePanel/Content/DeviceCount") as Label
	_check("one card per device", cards.get_child_count() == 4,
		"cards=%d" % cards.get_child_count())
	_check("card count caption", count.text == "УСТРОЙСТВА КОРАБЛЯ / 04", count.text)
	var titles: Array[String] = []
	for card in cards.get_children():
		titles.append((card as UpgradeDeviceCard).get_node("Content/Info/Title").text)
	_check("scanner card", titles.has("СКАНЕР ОБЗОРА"), str(titles))
	_check("signal light card", titles.has("СИГНАЛЬНЫЕ ОГНИ"), str(titles))
	_check("decoy card", titles.has("ЛОЖНЫЕ ЦЕЛИ"), str(titles))
	_check("first device is selected", screen.current_device() != null
		and screen.current_device().id == "scanner", "")
	var first_status := _cards(screen).get_child(0).get_node(
		"Content/Info/BottomRow/Status") as Label
	_check("card status is readable", first_status.text == "ДОСТУПНО"
		and first_status.size.x > 24.0,
		"%s w=%f" % [first_status.text, first_status.size.x])
	_check("device level line", _device_level(screen).text == "УР. 6 / 14 · ДОСТУПНО",
		_device_level(screen).text)

	# A card reports its selection upwards; the screen switches the detail panel.
	(cards.get_child(1) as UpgradeDeviceCard).selected.emit("signal_light")
	await process_frame
	_check("card selects its device", screen.current_device() != null
		and screen.current_device().id == "signal_light", "")
	_check("detail follows the selection", _device_name(screen).text == "СИГНАЛЬНЫЕ ОГНИ",
		_device_name(screen).text)
	_check("selected device shows its own paths", _rows(screen).get_child_count() == 4,
		"rows=%d" % _rows(screen).get_child_count())
	screen.select_device("decoy_launcher")
	await process_frame
	_check("explicit selection", _device_name(screen).text == "ЛОЖНЫЕ ЦЕЛИ",
		_device_name(screen).text)
	screen.select_device("nope")
	await process_frame
	_check("unknown device is ignored",
		screen.current_device() != null and screen.current_device().id == "decoy_launcher",
		"" if screen.current_device() == null else screen.current_device().id)
	screen.queue_free()
	await process_frame


func _check_paths() -> void:
	var screen := _make_screen()
	await process_frame
	var rows := _rows(screen)
	_check("scanner has five paths", rows.get_child_count() == 5,
		"rows=%d" % rows.get_child_count())
	var range_row := rows.get_child(0) as UpgradePathRow
	var time_row := rows.get_child(1) as UpgradePathRow
	var sense_row := rows.get_child(2) as UpgradePathRow
	_check("path title", _row_text(range_row, "Title") == "ДАЛЬНОСТЬ ОБЗОРА",
		_row_text(range_row, "Title"))
	_check("path level", _row_text(range_row, "Level") == "УР. 2/4",
		_row_text(range_row, "Level"))
	_check("current and next characteristic",
		_row_text(range_row, "Change") == "1719 px → 2148 px", _row_text(range_row, "Change"))
	_check("price in XP", _row_text(range_row, "Cost") == "0200 XP", _row_text(range_row, "Cost"))
	_check("available path is marked", _row_text(range_row, "Status") == "ДОСТУПНО",
		_row_text(range_row, "Status"))
	_check("unaffordable path is marked",
		_row_text(time_row, "Status") == "НЕДОСТАТОЧНО XP", _row_text(time_row, "Status"))
	_check("unaffordable price is still shown", _row_text(time_row, "Cost") == "0400 XP",
		_row_text(time_row, "Cost"))
	_check("sweep time reads in seconds",
		_row_text(time_row, "Change") == "2.1 с → 1.8 с", _row_text(time_row, "Change"))
	_check("multiplier reads as a factor",
		_row_text(sense_row, "Change") == "×1.20 → ×1.44", _row_text(sense_row, "Change"))
	var stats := screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/Stats") as GridContainer
	_check("characteristics grid is filled", stats.get_child_count() == 10,
		"cells=%d" % stats.get_child_count())
	var readable := ""
	var cell_index := 0
	for cell in stats.get_children():
		var control := cell as Control
		if control.size.x <= 4.0:
			readable += "cell %d w=%f " % [cell_index, control.size.x]
		cell_index += 1
	_check("characteristics have a readable width", readable.is_empty(), readable)
	_check("selected path information is shown",
		_selected_info(screen).text.contains("СЛЕДУЮЩИЙ УРОВЕНЬ · 0200 XP · 2148 px"),
		_selected_info(screen).text)
	time_row.selected.emit("scanner.scan_time")
	await process_frame
	_check("selecting a path updates the information block",
		_selected_info(screen).text.contains("0400 XP"), _selected_info(screen).text)
	screen.queue_free()
	await process_frame


func _row_text(row: UpgradePathRow, node_name: String) -> String:
	var path := "Content/TopRow/" + node_name
	if node_name == "Change" or node_name == "Cost":
		path = "Content/BottomRow/" + node_name
	return (row.get_node(path) as Label).text


func _check_action_is_a_request() -> void:
	var screen := _make_screen()
	await process_frame
	var requests: Array = []
	screen.upgrade_requested.connect(func(device_id: String, upgrade_id: String) -> void:
		requests.append([device_id, upgrade_id]))
	var action := _action(screen)
	_check("affordable path enables the action", not action.disabled, action.text)
	_check("action states the price", action.text == "УЛУЧШИТЬ ЗА 0200 XP", action.text)
	action.emit_signal("pressed")
	await process_frame
	_check("action only emits an upgrade request",
		requests.size() == 1 and requests[0] == ["scanner", "scanner.range"], str(requests))
	_check("nothing is spent", screen.xp() == 340, "xp=%d" % screen.xp())
	_check("no level is granted", screen.current_device().level() == 6,
		"level=%d" % screen.current_device().level())

	(_rows(screen).get_child(1) as UpgradePathRow).selected.emit("scanner.scan_time")
	await process_frame
	_check("unaffordable path disables the action", action.disabled, action.text)
	_check("action explains the refusal", action.text == "НЕДОСТАТОЧНО RESEARCH XP", action.text)
	screen.queue_free()
	await process_frame


func _check_maxed_path() -> void:
	var screen := _make_screen()
	await process_frame
	screen.select_device("signal_light")
	await process_frame
	var intensity := _rows(screen).get_child(2) as UpgradePathRow
	_check("maxed path is marked", _row_text(intensity, "Status") == "МАКСИМУМ",
		_row_text(intensity, "Status"))
	_check("maxed path shows no price", _row_text(intensity, "Cost") == "—",
		_row_text(intensity, "Cost"))
	_check("maxed path closes its characteristic",
		_row_text(intensity, "Change") == "×2.07 · ПРЕДЕЛ", _row_text(intensity, "Change"))
	intensity.selected.emit("signal_light.intensity")
	await process_frame
	_check("maxed path disables the action", _action(screen).disabled, _action(screen).text)
	_check("maxed action says so", _action(screen).text == "МАКСИМАЛЬНЫЙ УРОВЕНЬ",
		_action(screen).text)
	_check("device card reflects an upgradable device",
		(_cards(screen).get_child(1).get_node("Content/Info/BottomRow/Status") as Label).text
		== "ДОСТУПНО",
		(_cards(screen).get_child(1).get_node("Content/Info/BottomRow/Status") as Label).text)
	screen.queue_free()
	await process_frame


func _check_xp_gain() -> void:
	var screen := _make_screen()
	await process_frame
	_check("badge shows the starting total", _badge_value(screen).text == "340",
		_badge_value(screen).text)
	_check("no gain is highlighted at start", not _badge_delta(screen).visible, "")
	screen.add_xp(150)
	await process_frame
	_check("badge follows a gain", _badge_value(screen).text == "490",
		_badge_value(screen).text)
	_check("a gain is highlighted", _badge_delta(screen).visible, _badge_delta(screen).text)
	_check("the highlight states the amount", _badge_delta(screen).text == "+150",
		_badge_delta(screen).text)
	var time_row := _rows(screen).get_child(1) as UpgradePathRow
	_check("affordability is re-derived", _row_text(time_row, "Status") == "ДОСТУПНО",
		_row_text(time_row, "Status"))
	time_row.selected.emit("scanner.scan_time")
	await process_frame
	_check("the action becomes available",
		not _action(screen).disabled and _action(screen).text == "УЛУЧШИТЬ ЗА 0400 XP",
		_action(screen).text)
	_check("no level is granted by a gain", screen.current_device().level() == 6,
		"level=%d" % screen.current_device().level())
	await create_timer(2.0).timeout
	await process_frame
	_check("the highlight fades", not _badge_delta(screen).visible, "")
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
		var outside := _visible_controls_inside(screen, bounds)
		_check("upgrades @ %dx%d stays readable" % [resolution.x, resolution.y],
			outside.is_empty(), outside)
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


func _check_empty_catalogue() -> void:
	var screen := _make_screen()
	await process_frame
	var empty: Array[UpgradeDevice] = []
	screen.set_data(0, empty)
	await process_frame
	var placeholder := screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/Placeholder") as Label
	var detail := screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent") as VBoxContainer
	_check("an empty catalogue shows the placeholder", placeholder.visible and not detail.visible, "")
	_check("an empty catalogue disables the action", _action(screen).disabled,
		_action(screen).text)
	_check("an empty catalogue clears the cards", _cards(screen).get_child_count() == 0,
		"cards=%d" % _cards(screen).get_child_count())
	screen.queue_free()
	await process_frame


func _check_readout_on_hud() -> void:
	var hud: Control = load("res://scenes/ui/screens/HUD.tscn").instantiate() as Control
	root.add_child(hud)
	await process_frame
	var value := hud.get_node_or_null(
		"SafeArea/Layout/TopRow/XpBadge/Content/Text/Value") as Label
	_check("the flight HUD foundation carries the readout", value != null
		and value.text == "340", "" if value == null else value.text)
	hud.queue_free()
	await process_frame


func _check_no_gameplay_coupling() -> void:
	var forbidden := ["res://scripts/", "ResearchUpgradeManager.new", "ResearchSystem.new",
		"ShipScanner.new", ".purchase("]
	var coupled := ""
	for path in UI_SOURCES:
		var source := FileAccess.get_file_as_string(path)
		for marker in forbidden:
			if source.contains(marker):
				coupled += "%s:%s " % [path.get_file(), marker]
	_check("the upgrades UI is not coupled to gameplay", coupled.is_empty(), coupled)

	# Stage 6.7 moved the purchase call into exactly one binding node. If that
	# seam ever leaks back into the presenter, or the binding stops spending,
	# the panel is either coupled again or no longer buys anything.
	var console_source := FileAccess.get_file_as_string(
		"res://ui/upgrades/upgrades_console.gd")
	var snapshot_source := FileAccess.get_file_as_string(
		"res://ui/upgrades/upgrades_snapshot.gd")
	_check("one binding node owns the purchase", console_source.contains(".purchase(")
		and console_source.contains("ResearchUpgradeManager"), "")
	_check("the live snapshot reads the manager",
		snapshot_source.contains("ResearchUpgradeManager")
		and snapshot_source.contains("manager.profile"), "")