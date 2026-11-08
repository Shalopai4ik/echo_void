extends SceneTree

## Stage 6.7 contract: the upgrades panel buys with real Research XP, the real
## devices change, and the panel is fed from the manager's signals.
##
## Built on `Ship.tscn` plus the mounted devices, the same way
## `research_upgrade_test.gd` mounts them, and on the real
## `scenes/ui/UpgradesConsole.tscn` binding.
##
## Run: godot --headless --path . --script tests/upgrades_integration_test.gd

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const CONSOLE_SCENE := preload("res://scenes/ui/UpgradesConsole.tscn")
const UPGRADE_PROFILE := preload("res://assets/research/research_upgrade_profile.tres")
const SCANNER_PROFILE := preload("res://assets/ship/scanner_profile.tres")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: Node2D
var _hub: ShipSystems
var _research: ResearchSystem
var _manager: ResearchUpgradeManager
var _scanner: ShipScanner
var _decoy: ShipDecoyLauncher
var _signal_light: ShipSignalLight
var _console: UpgradesConsole
var _screen: UpgradesScreen
var _purchases: Array = []
var _refusals: Array = []


func _check(desc: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", desc, "  ", detail)
	else:
		_failed += 1
		print("FAIL  ", desc, "  ", detail)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_ship()
	var console := CONSOLE_SCENE.instantiate() as UpgradesConsole
	_root.add_child(console)
	_console = console
	_manager.upgrade_purchased.connect(func(id: String, level: int, spent: int,
			remaining: int) -> void:
		_purchases.append([id, level, spent, remaining])
	)
	_manager.upgrade_refused.connect(func(id: String, reason: String) -> void:
		_refusals.append([id, reason])
	)
	# One idle frame so the console's `_ready` (and the panel's) has run.
	await process_frame
	_screen = console.screen()
	_check_wiring()
	_check_purchase()
	_check_insufficient()
	_check_max_level()
	_check_gameplay_effects()
	_check_signal_light()
	_check_xp_gain()
	_check_save_load()
	_check_teardown()
	print("")
	print("=== Results: %d checks, %d failed ===" % [_checks, _failed])
	print("RESULT: ", "FAILURE" if _failed > 0 else "ALL PASS")
	quit(1 if _failed > 0 else 0)


## ---------------------------------------------------------------- fixture ---

func _build_ship() -> void:
	_root = Node2D.new()
	get_root().add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	_hub = _ship.get_node("Systems") as ShipSystems

	_research = ResearchSystem.new()
	_research.component_id = "research"
	_research.title = "Research Desk"
	_research.nominal_power_draw = 4.0
	_research.starts_enabled = false
	_hub.add_child(_research)
	_research.set_enabled(true)
	_research.from_dict({"xp": 1000, "progress": {}})

	_scanner = ShipScanner.new()
	_scanner.component_id = "scanner"
	_scanner.title = "Survey Scanner"
	_scanner.profile = SCANNER_PROFILE.duplicate()
	_scanner.nominal_power_draw = 6.0
	_scanner.starts_enabled = false
	_hub.add_child(_scanner)

	_decoy = ShipDecoyLauncher.new()
	_decoy.component_id = "decoy_launcher"
	_decoy.title = "Decoy Launcher"
	_decoy.nominal_power_draw = 5.0
	_decoy.starts_enabled = false
	_hub.add_child(_decoy)

	_manager = ResearchUpgradeManager.new()
	_manager.profile = UPGRADE_PROFILE.duplicate()
	_manager.research_component_id = "research"
	_hub.add_child(_manager)


## ------------------------------------------------------------------- checks ---

func _check_wiring() -> void:
	print("\n=== Phase A: panel is wired to the ship ===")
	_check("console found the manager", _console.manager() == _manager)
	_check("panel starts closed in flight", not _screen.is_open())
	_screen.open()
	_check("panel shows the research desk's XP", _badge_value().text == "1 000",
		_badge_value().text)
	_check("only mounted devices get a card", card_count() == 3, "cards=%d" % card_count())
	var titles: Array[String] = []
	for card in _cards().get_children():
		titles.append((card as UpgradeDeviceCard).get_node("Content/Info/Title").text)
	_check("scanner and decoy are listed", titles.has("СКАНЕР ОБЗОРА")
		and titles.has("ЛОЖНЫЕ ЦЕЛИ"), str(titles))
	_check("an unmounted signal light is not offered",
		not titles.has("СИГНАЛЬНЫЕ ОГНИ"), str(titles))
	var range_row := _row(0)
	_check("live characteristic is read from the device",
		_row_text(range_row, "Change") == "1100 px → 1375 px",
		_row_text(range_row, "Change"))
	_check("price comes from the catalogue", _row_text(range_row, "Cost") == "0050 XP",
		_row_text(range_row, "Cost"))
	_check("scanner level starts at zero", _device_level().text == "УР. 0 / 14 · ДОСТУПНО",
		_device_level().text)
	_check("action is enabled and names the price",
		not _action().disabled and _action().text == "УЛУЧШИТЬ ЗА 0050 XP",
		_action().text)


func _check_purchase() -> void:
	print("\n=== Phase B: a purchase spends once and changes the device ===")
	_refusals.clear()
	_purchases.clear()
	var before := _research.get_xp()
	_action().emit_signal("pressed")
	_check("one press buys exactly one level", _manager.get_level("scanner.range") == 1,
		"level=%d" % _manager.get_level("scanner.range"))
	_check("one press emits exactly one purchase", _purchases.size() == 1,
		str(_purchases))
	_check("XP is spent exactly once", _research.get_xp() == before - 50,
		"xp=%d" % _research.get_xp())
	_check("the mounted scanner changed", is_equal_approx(_scanner.range_multiplier, 1.25),
		"range_multiplier=%f" % _scanner.range_multiplier)
	_check("the gameplay range follows the upgrade",
		absf(_scanner.range_now() - 1375.0) <= 0.01, "range=%f" % _scanner.range_now())
	_check("the badge follows the spend", _badge_value().text == "950", _badge_value().text)
	_check("the level is refreshed", _row_text(_row(0), "Level") == "УР. 1/4",
		_row_text(_row(0), "Level"))
	_check("the next price is refreshed", _row_text(_row(0), "Cost") == "0100 XP",
		_row_text(_row(0), "Cost"))
	_check("the next value is refreshed",
		_row_text(_row(0), "Change") == "1375 px → 1719 px", _row_text(_row(0), "Change"))
	_check("the selection survived the refresh",
		_screen.current_device() != null and _screen.current_device().id == "scanner"
		and _screen.current_upgrade() != null
		and _screen.current_upgrade().id == "scanner.range", "")
	_check("the footer confirms the purchase",
		_hint().text.contains("УЛУЧШЕНО ДО УР. 1"), _hint().text)
	_check("a healthy purchase is not refused", _refusals.is_empty(), str(_refusals))

	_action().emit_signal("pressed")
	_check("a second press buys the next level", _manager.get_level("scanner.range") == 2
		and _research.get_xp() == before - 150,
		"level=%d xp=%d" % [_manager.get_level("scanner.range"), _research.get_xp()])


func _check_insufficient() -> void:
	print("\n=== Phase C: too little XP refuses without spending ===")
	_research.spend_xp(_research.get_xp() - 100)
	_console.refresh()
	_check("an outside spend refreshes the badge", _badge_value().text == "100",
		_badge_value().text)
	_check("the path is marked unaffordable",
		_row_text(_row(0), "Status") == "НЕДОСТАТОЧНО XP", _row_text(_row(0), "Status"))
	_check("the action is blocked",
		_action().disabled and _action().text == "НЕДОСТАТОЧНО RESEARCH XP",
		_action().text)
	var before := _research.get_xp()
	var level := _manager.get_level("scanner.range")
	_action().emit_signal("pressed")
	_check("a press on a blocked path buys nothing",
		_manager.get_level("scanner.range") == level and _research.get_xp() == before,
		"level=%d xp=%d" % [_manager.get_level("scanner.range"), _research.get_xp()])
	_check("the manager refuses directly", not _manager.purchase("scanner.range"), "")
	_check("the refusal is reported", _hint().text.contains("НЕДОСТАТОЧНО RESEARCH XP"),
		_hint().text)
	_check("the refusal did not spend", _research.get_xp() == before,
		"xp=%d" % _research.get_xp())


func _check_max_level() -> void:
	print("\n=== Phase D: maximum level is final ===")
	_research.from_dict({"xp": 10000, "progress": {}})
	_console.refresh()
	_manager.purchase("scanner.range")
	_manager.purchase("scanner.range")
	_screen.open()
	_check("the path reached its catalogue maximum",
		_manager.get_level("scanner.range") == 4,
		"level=%d" % _manager.get_level("scanner.range"))
	_check("the row is marked maxed", _row_text(_row(0), "Status") == "МАКСИМУМ",
		_row_text(_row(0), "Status"))
	_check("a maxed row shows no price", _row_text(_row(0), "Cost") == "—",
		_row_text(_row(0), "Cost"))
	_check("the action is blocked at the maximum",
		_action().disabled and _action().text == "МАКСИМАЛЬНЫЙ УРОВЕНЬ", _action().text)
	var before := _research.get_xp()
	_check("the manager refuses past the maximum", not _manager.purchase("scanner.range"), "")
	_check("a maximum refusal spends nothing", _research.get_xp() == before,
		"xp=%d" % _research.get_xp())
	_check("the scanner really reached the top range",
		absf(_scanner.range_multiplier - 2.44140625) <= 0.0001,
		"range_multiplier=%f" % _scanner.range_multiplier)


func _check_gameplay_effects() -> void:
	print("\n=== Phase E: other mounted devices take their own upgrades ===")
	_check("sweep time starts at its profile value",
		absf(_scanner.sweep_seconds_now() - 3.5) <= 0.001,
		"sweep=%f" % _scanner.sweep_seconds_now())
	_screen.select_device("scanner")
	_screen.select_upgrade("scanner.scan_time")
	_check("the sweep path is affordable", not _action().disabled, _action().text)
	_action().emit_signal("pressed")
	_check("the sweep is faster in gameplay",
		absf(_scanner.sweep_seconds_now() - 2.975) <= 0.001,
		"sweep=%f" % _scanner.sweep_seconds_now())
	_check("the sweep row reads the new value",
		_row_text(_rows().get_child(1), "Change") == "3.0 с → 2.5 с",
		_row_text(_rows().get_child(1), "Change"))

	_screen.select_device("decoy_launcher")
	_check("the decoy card is selected", _screen.current_device().id == "decoy_launcher", "")
	_screen.select_upgrade("decoy.speed")
	_check("the decoy speed path is affordable", not _action().disabled, _action().text)
	_action().emit_signal("pressed")
	_check("the decoy flies faster in gameplay",
		absf(_decoy.decoy_speed - 180.0) <= 0.01, "speed=%f" % _decoy.decoy_speed)
	_check("the decoy row reads the new value",
		_row_text(_rows().get_child(2), "Change") == "180 px/s → 216 px/s",
		_row_text(_rows().get_child(2), "Change"))
	_screen.select_upgrade("decoy.lifetime")
	_action().emit_signal("pressed")
	_check("the decoy lives longer in gameplay",
		absf(_decoy.decoy_lifetime - 25.0) <= 0.01, "lifetime=%f" % _decoy.decoy_lifetime)


func _check_signal_light() -> void:
	print("\n=== Phase F: a device mounted later appears with its own paths ===")
	_signal_light = ShipSignalLight.new()
	_signal_light.component_id = "signal_light"
	_signal_light.title = "Signal Light"
	_signal_light.nominal_power_draw = 2.0
	_signal_light.starts_enabled = false
	_hub.add_child(_signal_light)
	_console.refresh()
	_check("the panel now offers four devices", card_count() == 4,
		"cards=%d" % card_count())
	_screen.select_device("signal_light")
	_check("the signal light has its four real paths", _rows().get_child_count() == 4,
		"rows=%d" % _rows().get_child_count())
	_check("its radius reads the device export",
		_row_text(_rows().get_child(0), "Change") == "600 px → 780 px",
		_row_text(_rows().get_child(0), "Change"))
	_screen.select_upgrade("signal_light.duration")
	_action().emit_signal("pressed")
	_check("the beacon burns longer in gameplay",
		absf(_signal_light.duration_sec - 18.75) <= 0.01,
		"duration=%f" % _signal_light.duration_sec)


func _check_xp_gain() -> void:
	print("\n=== Phase G: research XP gained outside the panel ===")
	_research.from_dict({"xp": 1200, "progress": {}})
	_research.xp_gained.emit(200, 1200)
	_console.refresh()
	_check("the badge shows the new total", _badge_value().text == "1 200",
		_badge_value().text)
	_check("the panel is still on the same device",
		_screen.current_device() != null
		and _screen.current_device().id == "signal_light", "")


func _check_save_load() -> void:
	print("\n=== Phase H: save data round-trips and re-applies ===")
	var manager_saved := _manager.to_dict()
	var research_saved := _research.to_dict()
	_check("save carries every level", manager_saved["levels"].has("scanner.range")
		and manager_saved["levels"].has("decoy.speed"), str(manager_saved["levels"]))
	_check("save carries the research XP", int(research_saved["xp"]) == 1200,
		str(research_saved["xp"]))

	# Simulate a fresh hull: devices back to their shipped values, then load.
	_scanner.range_multiplier = 1.0
	_scanner.sweep_seconds_multiplier = 1.0
	_decoy.decoy_speed = 150.0
	_decoy.decoy_lifetime = 20.0
	var manager2 := ResearchUpgradeManager.new()
	manager2.profile = UPGRADE_PROFILE.duplicate()
	manager2.research_component_id = "research"
	_hub.add_child(manager2)
	var loaded := manager2.from_dict(manager_saved)
	_check("load accepted the payload", loaded == true, "")
	_check("the loaded levels match", manager2.get_level("scanner.range") == 4
		and manager2.get_level("decoy.speed") == 1,
		"range=%d speed=%d" % [manager2.get_level("scanner.range"),
			manager2.get_level("decoy.speed")])
	_check("loading re-applies the range to the device",
		is_equal_approx(_scanner.range_multiplier, 2.44140625),
		"range_multiplier=%f" % _scanner.range_multiplier)
	_check("loading re-applies the decoy speed",
		absf(_decoy.decoy_speed - 180.0) <= 0.01, "speed=%f" % _decoy.decoy_speed)

	var fresh_research := ResearchSystem.new()
	_check("XP loads into a fresh desk",
		fresh_research.from_dict(research_saved) and fresh_research.get_xp() == 1200,
		"xp=%d" % fresh_research.get_xp())
	fresh_research.free()
	manager2.queue_free()


func _check_teardown() -> void:
	print("\n=== Phase I: teardown ===")
	_ship.queue_free()
	_console.queue_free()
	_root.queue_free()


## ------------------------------------------------------------------ helpers ---

func _cards() -> VBoxContainer:
	return _screen.get_node(
		"SafeArea/Layout/Body/DevicePanel/Content/Scroll/DeviceList") as VBoxContainer


func card_count() -> int:
	return _cards().get_child_count()


func _rows() -> VBoxContainer:
	return _screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/PathList") as VBoxContainer


func _row(index: int) -> UpgradePathRow:
	return _rows().get_child(index) as UpgradePathRow


func _row_text(row: UpgradePathRow, node_name: String) -> String:
	var path := "Content/TopRow/" + node_name
	if node_name == "Change" or node_name == "Cost":
		path = "Content/BottomRow/" + node_name
	return (row.get_node(path) as Label).text


func _device_level() -> Label:
	return _screen.get_node(
		"SafeArea/Layout/Body/Detail/Scroll/DetailContent/DetailHeader/Info/DeviceLevel") as Label


func _action() -> Button:
	return _screen.get_node("SafeArea/Layout/Footer/Action") as Button


func _hint() -> Label:
	return _screen.get_node("SafeArea/Layout/Footer/Hint") as Label


func _badge_value() -> Label:
	return _screen.get_node(
		"SafeArea/Layout/Header/XpBadge/Content/Text/Value") as Label


func _physics_process(_delta: float) -> bool:
	return true