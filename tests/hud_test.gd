extends SceneTree

## Headless test for the HUD: one glass, two hulls.
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


func _run() -> void:
	await _current_slice()
	await _legacy_slice()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  hud")
	quit(1 if _failed > 0 else 0)


## The current slice: SpaceMap, the current hull, the current world field.
func _current_slice() -> void:
	print("-- the current slice: SpaceMap and the current hull")
	var scene: Node = load("res://scenes/world/SpaceMap.tscn").instantiate()
	root.add_child(scene)
	var hud: Control = scene.get_node("HUD/Root")
	var ship: Node2D = scene.get_node("Ship")
	var world: Node = scene.get_node("Field")
	await process_frame
	await _steps(20)

	var state: Dictionary = hud.hud_state()

	_check("the current slice has a glass of its own", hud != null, "")
	_check("it found the current hull",
		bool(state.get("ship_bound")) and str(state.get("slice")) == "current",
		"slice=" + str(state.get("slice")))
	_check("it does not pretend the hull has armour", not bool(state.get("armour")), "")
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

	scene.queue_free()
	await process_frame
	await _steps(2)


## The legacy slice: main.tscn, the old hull with its armour, the old belt.
func _legacy_slice() -> void:
	print("-- the legacy slice: main.tscn and the old hull")
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await _steps(20)

	var hud: Control = scene.get_node("HUD/Root")
	var player: Node2D = scene.get_node("Player")
	var state: Dictionary = hud.hud_state()

	_check("it found the old hull", str(state.get("slice")) == "legacy",
		"slice=" + str(state.get("slice")))
	_check("the old hull still gets its bars", bool(state.get("armour")), "")
	_check("the mission rows stay as they were written", bool(state.get("rows")), "")
	_check("the bars follow the hull's shield",
		absf(hud.shield_display() - player.shield_ratio()) < 0.02,
		"%.2f vs %.2f" % [hud.shield_display(), player.shield_ratio()])
	_check("and the old hull has no telemetry block",
		(state.get("telemetry") as Array).is_empty(),
		str(state.get("telemetry")))

	scene.queue_free()
	await process_frame
	await _steps(2)
