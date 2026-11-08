extends SceneTree

## Headless test for the interface layer of stage 7: the equipment panel, the
## four slots, the sector card, the pause menu and the panels around the ship.
##
## What it proves:
##   1. an open panel really holds the world - the hull's position and both of
##      its velocities come back bit for bit;
##   2. the energy reserve does not move while a panel is up, so the pause
##      does not touch the energy balance;
##   3. the equipment panel shows the hull's own devices;
##   4. the four slot keys reach the hull's own devices, and an empty slot
##      does nothing at all;
##   5. the sector card reads the research desk's own numbers;
##   6. one panel at a time: opening one closes the other.
##
## Run: godot --headless --path . --script tests/interface_integration_test.gd

var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("PASS  ", name, "  ", detail)
	else:
		_failed += 1
		print("FAIL  ", name, "  ", detail)


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


## Press and release a key as a real event, so the consumers see it the way
## they do in front of a keyboard. Both the key code and the physical key code
## are set, because Godot's own `ui_cancel` is bound by key code while this
## project's own actions are bound by physical key code.
func _press_key(keycode: int) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventKey.new()
	up.keycode = keycode
	up.physical_keycode = keycode
	up.pressed = false
	Input.parse_input_event(up)


func _run() -> void:
	await _interface_cycle()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  interface")
	quit(1 if _failed > 0 else 0)


func _interface_cycle() -> void:
	print("-- the interface layer of the flight scene")
	var scene: Node = load("res://scenes/world/SpaceMap.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await _steps(10)

	var ship: RigidBody2D = scene.get_node("Ship") as RigidBody2D
	var systems: ShipSystems = scene.get_node("Ship/Systems") as ShipSystems
	var slots: EquipmentSlots = scene.get_node("Ship/Systems/Slots") as EquipmentSlots
	# Slot 4 carries the signal lights in the flight scene. The "an empty slot
	# does nothing" rule is checked here on a copy with slot 4 left empty; the
	# flares in slot 4 are checked at the end against the real binding.
	slots.slot_bindings = PackedStringArray(["scanner", "research", "decoy_launcher", ""])
	var equipment := scene.get_node("EquipmentConsole") as EquipmentConsole
	var pause_console := scene.get_node("PauseMenuConsole") as PauseMenuConsole
	var scanner_console := scene.get_node("ScannerConsole") as ScannerConsole
	var research_console := scene.get_node("ResearchConsole") as ResearchConsole

	_check("the flight scene carries every console",
		equipment != null and pause_console != null and scanner_console != null
			and research_console != null, "")

	# --- the panels hold the world -------------------------------------------
	ship.linear_velocity = Vector2(90.0, 12.0)
	ship.angular_velocity = 0.4
	await _steps(2)
	var energy_before := systems.energy_charge()
	var position_before := ship.global_position
	var linear_before := ship.linear_velocity
	var angular_before := ship.angular_velocity

	equipment.open_panel()
	await _steps(4)
	_check("an open panel is in the modal group",
		equipment.screen().is_in_group("ui_modal"), "")
	_check("an open panel stops the hull's own work",
		ship.process_mode == Node.PROCESS_MODE_DISABLED, str(ship.process_mode))
	_check("an open panel holds the hull still",
		ship.global_position.is_equal_approx(position_before)
			and ship.linear_velocity.is_equal_approx(linear_before)
			and is_equal_approx(ship.angular_velocity, angular_before),
		"%s -> %s" % [str(position_before), str(ship.global_position)])

	# --- the equipment panel is the hull's own -------------------------------
	var grid := equipment.screen().get_node("SafeArea/Layout/Scroll/Grid") as GridContainer
	_check("the panel shows one card per slot",
		grid.get_child_count() == EquipmentSlots.SLOT_COUNT,
		"%d cards" % grid.get_child_count())
	var first_card := grid.get_child(0) as EquipmentCard
	var hub_title := str((systems.equipment_status("scanner") as Dictionary).get("title", ""))
	_check("the first card is the scanner the hull carries",
		first_card != null and first_card.card_title() == hub_title.to_upper(),
		"%s vs %s" % ["" if first_card == null else first_card.card_title(),
			hub_title.to_upper()])

	# --- the card's button throws the hull's own switch ----------------------
	# The card is asked for again each time: the panel rebuilds itself when the
	# ship says a device changed, so the old card is gone by then.
	systems.set_enabled("scanner", false)
	await _steps(1)
	(grid.get_child(0) as EquipmentCard).action_requested.emit("scanner", "switch")
	await _steps(2)
	_check("the card's button throws the hull's switch",
		systems.is_enabled("scanner"),
		"scanner=%s" % str(systems.is_enabled("scanner")))
	(grid.get_child(0) as EquipmentCard).action_requested.emit("scanner", "switch")
	await _steps(2)
	_check("and throws it back",
		not systems.is_enabled("scanner"),
		"scanner=%s" % str(systems.is_enabled("scanner")))

	# --- the slot keys -------------------------------------------------------
	# The keys belong to the pilot only while no panel is up: a panel that is
	# open owns the keyboard. So the panel is closed first.
	equipment.close_panel()
	await _steps(2)
	systems.set_enabled("scanner", false)
	await _steps(1)
	_press_key(KEY_1)
	await process_frame
	await _steps(2)
	_check("slot 1 throws the scanner's switch",
		systems.is_enabled("scanner"), "scanner=%s" % str(systems.is_enabled("scanner")))
	_press_key(KEY_1)
	await process_frame
	await _steps(2)
	_check("slot 1 throws it back",
		not systems.is_enabled("scanner"), "scanner=%s" % str(systems.is_enabled("scanner")))

	var energy_before_slots := systems.energy_charge()
	_press_key(KEY_4)
	await process_frame
	await _steps(2)
	_check("an empty slot does nothing",
		absf(systems.energy_charge() - energy_before_slots) < 0.0001,
		"charge %s -> %s" % [str(energy_before_slots), str(systems.energy_charge())])

	# --- the pause does not touch the energy balance -------------------------
	_check("the reserve did not move while the panel was up",
		absf(systems.energy_charge() - energy_before) < 0.0001,
		"%s -> %s" % [str(energy_before), str(systems.energy_charge())])

	# --- one panel at a time -------------------------------------------------
	pause_console.open_panel()
	await _steps(2)
	_check("opening the pause menu closes the equipment panel",
		pause_console.is_panel_open() and not equipment.is_panel_open(),
		"pause=%s equipment=%s" % [str(pause_console.is_panel_open()),
			str(equipment.is_panel_open())])
	_check("the pause menu is the one open panel",
		get_nodes_in_group("ui_modal").size() == 1,
		str(get_nodes_in_group("ui_modal").size()))

	pause_console.close_panel()
	await _steps(2)
	_check("closing the pause menu gives the world back",
		ship.process_mode != Node.PROCESS_MODE_DISABLED
			and get_nodes_in_group("ui_modal").is_empty(),
		str(ship.process_mode))

	# --- the panel hands the pilot over to another panel ----------------------
	equipment.open_panel()
	await _steps(2)
	equipment.screen().scanner_requested.emit()
	await _steps(2)
	_check("the equipment panel hands over to the scope",
		scanner_console.is_panel_open() and not equipment.is_panel_open(),
		"scanner=%s equipment=%s" % [str(scanner_console.is_panel_open()),
			str(equipment.is_panel_open())])
	scanner_console.close_panel()
	await _steps(2)

	# --- Escape closes the pause menu -----------------------------------------
	pause_console.open_panel()
	await _steps(2)
	_check("the pause menu is open before the key",
		pause_console.is_panel_open(), "")
	_press_key(KEY_ESCAPE)
	await process_frame
	await _steps(2)
	_check("Escape closes the pause menu",
		not pause_console.is_panel_open()
			and get_nodes_in_group("ui_modal").is_empty(),
		"open=%s" % str(pause_console.is_panel_open()))

	# --- the sector card reads the desk --------------------------------------
	var desk := scene.get_node("Ship/Systems/Research") as ResearchSystem
	var sector := SectorObjective.build(desk)
	var desk_subjects := (desk.to_dict().get("progress", {}) as Dictionary).size()
	_check("the sector card counts the desk's own subjects",
		int(sector.get("discovered", 0)) == int(desk_subjects),
		"discovered=%d subjects=%d" % [int(sector.get("discovered", 0)), int(desk_subjects)])

	# --- the scope and the desk read the ship --------------------------------
	scanner_console.open_panel()
	await _steps(2)
	_check("the scope opens on the real scanner",
		scanner_console.is_panel_open(), "")
	scanner_console.close_panel()
	await _steps(2)

	research_console.open_panel()
	await _steps(2)
	_check("the research panel opens on the real desk",
		research_console.is_panel_open(), "")
	research_console.close_panel()
	await _steps(2)

	# --- the slot registry agrees with the hub -------------------------------
	var slot_state := slots.slot_status(0)
	_check("slot 1 is the scanner the hub knows",
		str(slot_state.get("component_id", "")) == "scanner",
		str(slot_state.get("component_id", "")))
	_check("slot 4 is empty and says so",
		bool(slots.slot_status(3).get("empty", false)), "")
	slots.slot_bindings = PackedStringArray(["scanner", "research", "decoy_launcher", "signal_light"])
	_check("with its real binding slot 4 is the signal lights",
		str(slots.slot_status(3).get("component_id", "")) == "signal_light"
		and int(slots.slot_status(3).get("charges", -1)) > 0, str(slots.slot_status(3)))

	scene.queue_free()
	await process_frame
	await _steps(2)
