extends SceneTree

## Verification of the research upgrade system: spending Research XP on
## equipment levels and seeing the changes applied to mounted devices.
## Run: godot --headless --path . --script tests/research_upgrade_test.gd

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const UPGRADE_PROFILE := preload("res://assets/research/research_upgrade_profile.tres")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: Node2D
var _hub: ShipSystems
var _research: ResearchSystem
var _manager: ResearchUpgradeManager
var _scanner: ShipScanner
var _signal_light: ShipSignalLight
var _decoy: ShipDecoyLauncher

## Events captured.
var _purchased: Array = []
var _refused: Array = []
var _xp_spent_events: Array = []

func _check(desc: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("PASS: ", desc)
	else:
		_failed += 1
		print("FAIL: ", desc)


func _fail(desc: String) -> void:
	_failed += 1
	_checks += 1
	print("FAIL: ", desc)


func _initialize() -> void:
	_root = Node2D.new()
	get_root().add_child(_root)

	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	_hub = _ship.get_node("Systems")
	assert(_hub != null, "Ship/Systems hub missing")

	# Mount a research desk with lots of XP.
	_research = ResearchSystem.new()
	_research.component_id = "research"
	_research.title = "Research Desk"
	_research.nominal_power_draw = 4.0
	_research.starts_enabled = false
	_hub.add_child(_research)
	_research._attach()
	_research.set_enabled(true)
	_research._xp = 10000

	# Mount the upgrade manager.
	_manager = ResearchUpgradeManager.new()
	_manager.profile = UPGRADE_PROFILE.duplicate()
	_manager.research_component_id = "research"
	_hub.add_child(_manager)
	_manager._find_research()

	# Wire signals.
	_manager.upgrade_purchased.connect(func(id, lvl, spent, remaining):
		_purchased.append([id, lvl, spent, remaining])
	)
	_manager.upgrade_refused.connect(func(id, reason):
		_refused.append([id, reason])
	)
	_manager.xp_spent.connect(func(amount, total):
		_xp_spent_events.append([amount, total])
	)

	# Mount devices the manager will upgrade.
	_scanner = ShipScanner.new()
	_scanner.component_id = "scanner"
	_scanner.title = "Survey Scanner"
	_scanner.profile = preload("res://assets/ship/scanner_profile.tres").duplicate()
	_scanner.nominal_power_draw = 6.0
	_scanner.starts_enabled = false
	_hub.add_child(_scanner)
	_scanner._attach()

	_signal_light = ShipSignalLight.new()
	_signal_light.component_id = "signal_light"
	_signal_light.title = "Signal Light"
	_signal_light.nominal_power_draw = 2.0
	_signal_light.starts_enabled = false
	_hub.add_child(_signal_light)
	_signal_light._attach()

	_decoy = ShipDecoyLauncher.new()
	_decoy.component_id = "decoy_launcher"
	_decoy.title = "Decoy Launcher"
	_decoy.nominal_power_draw = 5.0
	_decoy.starts_enabled = false
	_hub.add_child(_decoy)
	_decoy._attach()
	print("=== Phase A: initial state ===")
	_check("manager finds research system", _manager.get_xp() == 10000)
	_check("scanner range multiplier is 1.0", is_equal_approx(_scanner.range_multiplier, 1.0))
	_check("scanner sensitivity is 1.0", is_equal_approx(_scanner.sensitivity, 1.0))
	_check("signal light radius is 600", is_equal_approx(_signal_light.radius_px, 600.0))
	_check("decoy lifetime is 20", is_equal_approx(_decoy.decoy_lifetime, 20.0))

	print("\n=== Phase B: buy scanner range level 1 ===")
	_check("can afford scanner.range", _manager.can_afford("scanner.range"))
	_check("next cost is 50", _manager.next_cost("scanner.range") == 50)
	var ok := _manager.purchase("scanner.range")
	_check("purchase succeeded", ok == true)
	_check("level is 1", _manager.get_level("scanner.range") == 1)
	_check("XP reduced by 50", _manager.get_xp() == 9950)
	_check("range multiplier is 1.25", is_equal_approx(_scanner.range_multiplier, 1.25))
	_check("purchased event fired", _purchased.size() == 1 and _purchased[0][0] == "scanner.range")
	_check("xp_spent event fired", _xp_spent_events.size() == 1 and _xp_spent_events[0][0] == 50)

	print("\n=== Phase C: buy scanner range level 2 ===")
	_check("can afford level 2", _manager.can_afford("scanner.range"))
	_check("next cost is 100", _manager.next_cost("scanner.range") == 100)
	ok = _manager.purchase("scanner.range")
	_check("purchase succeeded", ok == true)
	_check("level is 2", _manager.get_level("scanner.range") == 2)
	_check("range multiplier is 1.5625 (1.25^2)", absf(_scanner.range_multiplier - 1.5625) <= 0.001)
	_check("XP is 9850", _manager.get_xp() == 9850)

	print("\n=== Phase D: insufficient XP ===")
	_research._xp = 5
	_check("cannot afford with 5 XP", not _manager.can_afford("scanner.range"))
	var spent_before := _xp_spent_events.size()
	ok = _manager.purchase("scanner.range")
	_check("purchase refused", ok == false)
	_check("refusal is insufficient_xp", _refused.size() > 0 and _refused[_refused.size()-1][1] == "insufficient_xp")
	_check("no extra xp_spent event", _xp_spent_events.size() == spent_before)
	_check("level still 2", _manager.get_level("scanner.range") == 2)
	_check("range multiplier unchanged", absf(_scanner.range_multiplier - 1.5625) <= 0.001)
	_research._xp = 10000

	print("\n=== Phase E: max level ===")
	# Buy levels 3 and 4 of scanner.range.
	_manager.purchase("scanner.range")
	_manager.purchase("scanner.range")
	_check("level is 4 (max)", _manager.get_level("scanner.range") == 4)
	ok = _manager.purchase("scanner.range")
	_check("purchase beyond max refused", ok == false)
	_check("refusal is max_level", _refused.size() > 0 and _refused[_refused.size()-1][1] == "max_level")
	_check("level still 4", _manager.get_level("scanner.range") == 4)

	print("\n=== Phase F: signal light upgrades ===")
	_check("can afford signal_light.radius", _manager.can_afford("signal_light.radius"))
	ok = _manager.purchase("signal_light.radius")
	_check("signal radius purchase succeeded", ok == true)
	_check("signal radius level 1", _manager.get_level("signal_light.radius") == 1)
	_check("radius_px is 780 (600*1.3)", absf(_signal_light.radius_px - 780.0) <= 0.01)

	ok = _manager.purchase("signal_light.duration")
	_check("signal duration purchase succeeded", ok == true)
	_check("duration_sec is 18.75 (15*1.25)", absf(_signal_light.duration_sec - 18.75) <= 0.01)

	ok = _manager.purchase("signal_light.intensity")
	_check("signal intensity purchase succeeded", ok == true)
	_check("intensity is 1.2 (1.0*1.2)", absf(_signal_light.intensity - 1.2) <= 0.01)

	print("\n=== Phase G: decoy upgrades ===")
	ok = _manager.purchase("decoy.lifetime")
	_check("decoy lifetime purchase succeeded", ok == true)
	_check("decoy lifetime level 1", _manager.get_level("decoy.lifetime") == 1)
	_check("decoy_lifetime is 25.0 (20*1.25)", absf(_decoy.decoy_lifetime - 25.0) <= 0.01)

	ok = _manager.purchase("decoy.signal")
	_check("decoy signal purchase succeeded", ok == true)
	_check("signal_intensity is 1.44 (1.2*1.2)", absf(_decoy.signal_intensity - 1.44) <= 0.01)

	ok = _manager.purchase("decoy.speed")
	_check("decoy speed purchase succeeded", ok == true)
	_check("decoy_speed is 180.0 (150*1.2)", absf(_decoy.decoy_speed - 180.0) <= 0.01)

	print("\n=== Phase H: unknown upgrade ===")
	_refused.clear()
	ok = _manager.purchase("nonexistent.upgrade")
	_check("purchase for unknown upgrade refused", ok == false)

	print("\n=== Phase I: save/load ===")
	var saved := _manager.to_dict()
	_check("saved has levels", saved.has("levels"))
	_check("saved has base_values", saved.has("base_values"))
	_check("saved scanner.range level is 4", int(saved["levels"]["scanner.range"]) == 4)
	_check("saved scanner.range base is 1.0", absf(float(saved["base_values"]["scanner.range"]) - 1.0) <= 0.001)

	var manager2 = ResearchUpgradeManager.new()
	manager2.profile = UPGRADE_PROFILE.duplicate()
	manager2.research_component_id = "research"
	_root.add_child(manager2)
	var loaded := manager2.from_dict(saved)
	_check("load returned true", loaded == true)
	_check("loaded level matches", manager2.get_level("scanner.range") == 4)

	print("\n=== Phase J: teardown ===")
	_ship.queue_free()
	_root.queue_free()

	print("")
	var result_text := "=== Results: %d checks, %d failed ===" % [_checks, _failed]
	print(result_text)
	if _failed == 0:
		print("RESULT: ALL PASS")
	else:
		print("RESULT: FAILURE")


func _physics_process(_delta: float) -> bool:
	return true
	pass
