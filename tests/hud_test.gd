extends SceneTree

## Headless test for the HUD: the glass of the one hull the game ships.
## Run: godot --headless --path . --script tests/hud_test.gd

var _failed := 0


## A stand-in for the mission system the current slice does not have yet. The HUD
## is written against this contract, so the objectives can be wired up later
## without touching the glass.
class MissionStub extends Node:
	func objective_title() -> String:
		return "ЗАДАЧА ЭТАПА 3:"
	func objective_lines() -> Array:
		return ["Дойти до аномалии.", "Снять показания."]


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


func _mentions(lines: Array, needle: String) -> bool:
	for line in lines:
		if str(line).contains(needle):
			return true
	return false


## Press and release the scanner key as a real event, so `_unhandled_input`
## consumers see it the way they do in front of a keyboard.
func _press_scan_key() -> void:
	var down := InputEventKey.new()
	down.physical_keycode = KEY_R
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventKey.new()
	up.physical_keycode = KEY_R
	up.pressed = false
	Input.parse_input_event(up)


func _run() -> void:
	await _current_slice()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  hud")
	quit(1 if _failed > 0 else 0)


## The current slice: SpaceMap, the current hull, the current world field.
func _current_slice() -> void:
	print("-- the current slice: SpaceMap and the current hull")
	var scene: Node = load("res://scenes/world/SpaceMap.tscn").instantiate()
	# This suite checks the HUD's mission *hook* against its own stand-in, so
	# the real storyline (MissionDirector) is taken out of this copy of the map;
	# demo_flow_test covers the real one.
	scene.get_node("Mission").free()
	root.add_child(scene)
	var hud: Control = scene.get_node("HUD/Root")
	var ship: Node2D = scene.get_node("Ship")
	var world: Node = scene.get_node("Field")
	await process_frame
	await _steps(20)

	var state: Dictionary = hud.hud_state()

	_check("the current slice has a glass of its own", hud != null, "")
	_check("it found the current hull", bool(state.get("ship_bound")), "")
	_check("it does not claim armour the hull does not have",
		not state.has("armour") and not state.has("slice"), str(state.keys()))
	_check("the mission rows stay hidden without a mission system",
		not bool(state.get("rows")), "")

	var lines: Array = state.get("telemetry", [])
	_check("it reads the hull's own numbers", lines.size() >= 4, "%d lines" % lines.size())
	_check("the speed is one of them", _mentions(lines, "СКОРОСТЬ"), str(lines))
	_check("the world is one of them", _mentions(lines, "МИР"), str(lines))

	# The radar: a sweep has to find the world's stones. The dish is opened all
	# the way up so the answer does not depend on where the belt happens to put
	# its rocks at this particular seed.
	hud.radar_range = 100000.0
	Input.action_press("scan")
	await process_frame
	await physics_frame
	Input.action_release("scan")
	await process_frame
	var contacts: Array = hud.contacts()
	var bodies: Array = world.bodies()
	_check("a sweep finds the world's stones", contacts.size() > 0,
		"%d contacts of %d bodies" % [contacts.size(), bodies.size()])
	_check("and no more than are out there", contacts.size() <= bodies.size(),
		"%d of %d" % [contacts.size(), bodies.size()])
	var shaped := 0
	var inside := 0
	for contact in contacts:
		if (contact["shape"] as Array).size() > 0:
			shaped += 1
		if (contact["at"] as Vector2).distance_to(ship.global_position) <= hud.radar_range:
			inside += 1
	_check("every contact carries its silhouette", shaped == contacts.size(),
		"%d of %d" % [shaped, contacts.size()])
	_check("every contact is inside the dish", inside == contacts.size(),
		"%d of %d" % [inside, contacts.size()])

	# The mission hook: a provider in the "mission" group brings the rows back
	# and fills them with its own lines.
	var stub := MissionStub.new()
	stub.add_to_group("mission")
	scene.add_child(stub)
	await process_frame
	await _steps(2)
	var after: Dictionary = hud.hud_state()
	_check("a mission provider brings the rows back", bool(after.get("rows")), "")
	_check("and the rows carry the provider's lines",
		(hud.get_node("Objective1") as Label).text == "Дойти до аномалии.",
		(hud.get_node("Objective1") as Label).text)
	_check("and so does the title",
		(hud.get_node("MissionTitle") as Label).text == "ЗАДАЧА ЭТАПА 3:",
		(hud.get_node("MissionTitle") as Label).text)

	# The mission block and the corner readouts share the left edge, so the rows
	# have to start under the hull block, keep their reading order and stop above
	# the telemetry - the three of them used to be drawn through each other.
	var title := hud.get_node("MissionTitle") as Label
	var mission_rows := [title, hud.get_node("Objective1") as Label,
		hud.get_node("Objective2") as Label, hud.get_node("Objective3") as Label]
	var ordered := true
	var separated := true
	for index in range(1, mission_rows.size()):
		var current: Label = mission_rows[index]
		var previous: Label = mission_rows[index - 1]
		if current.position.y <= previous.position.y:
			ordered = false
		if current.position.y < previous.position.y + previous.size.y:
			separated = false
	_check("the mission rows read top to bottom", ordered, "")
	_check("no mission row sits on the one above it", separated, "")
	_check("the mission block clears the hull status block", title.position.y >= 76.0,
		str(title.position))
	var metrics: Dictionary = hud.hud_metrics()
	var telemetry_top := float((metrics["telemetry_origin"] as Vector2).y)
	var last_row: Label = mission_rows[mission_rows.size() - 1]
	_check("the mission block clears the telemetry block",
		last_row.position.y + last_row.size.y < telemetry_top,
		"last=%s telemetry_top=%.1f" % [str(last_row.position), telemetry_top])

	# The scan key is a ship control, so it has to be advertised and it must not
	# sit under the radar dish it feeds.
	var prompt := hud.get_node("Scanner") as Control
	_check("the scan key is advertised on the glass", prompt.modulate.a > 0.5,
		str(prompt.modulate))
	_check("the prompt clears the radar dish",
		prompt.position.x + prompt.size.x <= hud.radar_center_at().x - hud.radar_radius,
		"prompt_right=%.1f dish_left=%.1f" % [
			prompt.position.x + prompt.size.x,
			hud.radar_center_at().x - hud.radar_radius])

	# Research XP in flight: the badge in the corner is fed by the research desk.
	var badge := hud.get_node("XpBadge") as ResearchXpBadge
	var research := ship.get_node("Systems/Research") as ResearchSystem
	research.xp_gained.emit(120, 120)
	await process_frame
	_check("the flight glass shows research XP", badge.value() == 120, str(badge.value()))
	research.xp_spent.emit(20, 100)
	await process_frame
	_check("a spend moves the badge down", badge.value() == 100, str(badge.value()))

	# An open panel owns the levers: the thrust key must not command a burn while
	# the pilot is reading a screen, and must command one again once it closes.
	var console := scene.get_node("UpgradesConsole") as UpgradesConsole
	console.screen().open()
	Input.action_press("thrust_forward")
	await _steps(3)
	var commanded_locked: float = (ship.get("commanded_acceleration") as Vector2).length()
	var locked_flag := bool(ship.get("interface_input_locked"))
	_check("an open panel takes the ship's levers",
		locked_flag and commanded_locked < 0.5,
		"locked=%s commanded=%.2f" % [str(locked_flag), commanded_locked])
	_check("and the panel is the thing the glass defers to",
		console.screen().is_in_group("ui_modal"), "")
	console.screen().close()
	await _steps(3)
	var commanded_free: float = (ship.get("commanded_acceleration") as Vector2).length()
	Input.action_release("thrust_forward")
	_check("closing the panel gives the levers back",
		not bool(ship.get("interface_input_locked")) and commanded_free > 1.0,
		"locked=%s commanded=%.2f" % [str(ship.get("interface_input_locked")), commanded_free])

	# R is also the scanner's key. Behind the panel the event must never reach the
	# device; with the panel gone the same key must reach it.
	var systems := ship.get_node("Systems") as ShipSystems
	systems.set_enabled("scanner", true)
	var scanner := ship.get_node("Systems/Scanner") as ShipScanner
	var heard: Array = []
	scanner.scan_started.connect(func(_range_px: float, _seconds: float) -> void:
		heard.append("started"))
	scanner.scan_refused.connect(func(reason: String) -> void:
		heard.append(reason))
	console.screen().open()
	await process_frame
	_press_scan_key()
	await process_frame
	await _steps(2)
	_check("the scan key does not reach the scanner behind the panel",
		heard.is_empty(), str(heard))
	console.screen().close()
	await process_frame
	_press_scan_key()
	await process_frame
	await _steps(2)
	_check("and does reach it once the panel is closed", not heard.is_empty(), str(heard))

	# Open/close cycles must not accumulate cards: the panel hides, it does not
	# rebuild itself into a leak.
	var device_list := console.screen().get_node(
		"SafeArea/Layout/Body/DevicePanel/Content/Scroll/DeviceList") as VBoxContainer
	var cards_before := device_list.get_child_count()
	for cycle in 3:
		console.screen().open()
		await process_frame
		console.screen().close()
		await process_frame
	_check("open/close cycles leave no extra cards",
		device_list.get_child_count() == cards_before,
		"%d -> %d" % [cards_before, device_list.get_child_count()])

	scene.queue_free()
	await process_frame
	await _steps(2)