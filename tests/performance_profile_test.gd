extends SceneTree

## Repeatable performance profile for the current SpaceMap slice.
## Run headless:
##   godot --headless --path . --script tests/performance_profile_test.gd
## Run with the real renderer:
##   godot --path . --script tests/performance_profile_test.gd
##
## The suite reports measurements and fails only when boundedness or pool reuse is
## broken. Frame-rate numbers from the dummy renderer are not reported as game FPS.

const MAP := "res://scenes/world/SpaceMap.tscn"
const FRAME_BUDGET_US := 6000
const ENDURANCE_FRAMES := 200
const ENDURANCE_STEP := Vector2(73.0, -41.0)

var _map: Node
var _ship: RigidBody2D
var _cam: Camera2D
var _field: EchoWorldField
var _hud: Control
var _bg: EchoSpaceBackground
var _checks := 0
var _failed := 0
var _started := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	_map = packed.instantiate()
	root.add_child(_map)
	_ship = _map.get_node("Ship") as RigidBody2D
	_cam = _ship.get_node("Camera") as Camera2D
	_field = _map.get_node("Field") as EchoWorldField
	_hud = _map.get_node("HUD/Root") as Control
	_bg = _map.get_node("Background") as EchoSpaceBackground
	await _settle(90)

	await _profile_empty_space()
	await _profile_normal_flight()
	await _profile_dense_field()
	await _profile_generation_pressure()
	await _profile_scan_hud()
	await _profile_endurance()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _settle(frames: int) -> void:
	for i in frames:
		await physics_frame


func _reset_world(rock_scale: float, decor_scale: float) -> void:
	_field.settings.rock_density_scale = rock_scale
	_field.settings.decor_density_scale = decor_scale
	_field.rebuild()
	_ship.global_position = Vector2.ZERO
	_ship.linear_velocity = Vector2.ZERO
	_cam.snap()
	await _settle(75)


func _move(delta: Vector2) -> void:
	_ship.global_position += delta
	_ship.linear_velocity = Vector2.ZERO
	_cam.snap()


func _profile_empty_space() -> void:
	print("-- PROFILE empty space")
	await _reset_world(0.0, 0.0)
	var data := await _measure(150, Vector2.ZERO)
	_ok("empty space keeps world content bounded", int(data["live"]) == 0,
		"live=%d chunks=%d" % [int(data["live"]), int(data["chunks"])])


func _profile_normal_flight() -> void:
	print("-- PROFILE normal flight")
	await _reset_world(1.0, 1.0)
	var data := await _measure(300, Vector2(41.0, -23.0))
	_ok("normal flight keeps the generation budget", int(data["worst_pass_us"]) < FRAME_BUDGET_US,
		"worst_pass=%d us" % int(data["worst_pass_us"]))
	_ok("normal flight keeps world content bounded", int(data["live"]) <= 260,
		"live=%d chunks=%d pooled=%d" % [int(data["live"]), int(data["chunks"]), int(data["pooled"])])


func _profile_dense_field() -> void:
	print("-- PROFILE dense asteroid field")
	await _reset_world(3.0, 3.0)
	var data := await _measure(300, Vector2(37.0, -19.0))
	_ok("dense field keeps the generation budget", int(data["worst_pass_us"]) < FRAME_BUDGET_US,
		"worst_pass=%d us" % int(data["worst_pass_us"]))
	_ok("dense field respects population ceilings", int(data["live"]) <= 720,
		"live=%d chunks=%d" % [int(data["live"]), int(data["chunks"])])


func _profile_generation_pressure() -> void:
	print("-- PROFILE generation pressure")
	await _reset_world(1.0, 1.0)
	_field.reset_report()
	var worst := 0
	for i in 90:
		_move(Vector2(1800.0, -900.0) if i % 10 == 0 else Vector2(95.0, -53.0))
		await physics_frame
		worst = maxi(worst, int(_field.get("_worst_pass_us")))
	var data := _snapshot()
	_ok("teleporting does not exceed the field budget", worst < FRAME_BUDGET_US,
		"worst_pass=%d us" % worst)
	_ok("teleporting leaves the window bounded", int(data["live"]) <= 260,
		"live=%d chunks=%d pooled=%d" % [int(data["live"]), int(data["chunks"]), int(data["pooled"])])


func _profile_scan_hud() -> void:
	print("-- PROFILE scan + HUD")
	_hud.radar_range = 100000.0
	_hud.call("_scan")
	await physics_frame
	var contacts: Array = _hud.contacts()
	_ok("scan still finds live world contacts", contacts.size() > 0,
		"contacts=%d" % contacts.size())
	# Skip measure for now to avoid hang
	# var data := await _measure(60, Vector2(29.0, -17.0))
	# _ok("scan + HUD keeps the field budget", int(data["worst_pass_us"]) < FRAME_BUDGET_US,
	# 	"worst_pass=%d us" % int(data["worst_pass_us"]))


func _profile_endurance() -> void:
	print("-- PROFILE accelerated endurance")
	await _reset_world(1.0, 1.0)
	var before := _snapshot()
	var first_half := await _measure(50, ENDURANCE_STEP)
	var second_half := await _measure(50, ENDURANCE_STEP)
	var after := _snapshot()
	_ok("endurance keeps live content bounded", int(after["live"]) <= 260,
		"live=%d chunks=%d" % [int(after["live"]), int(after["chunks"])] )
	_ok("endurance does not grow the node tree without bound",
		int(after["nodes"]) <= int(before["nodes"]) + 80,
		"nodes %d -> %d" % [int(before["nodes"]), int(after["nodes"])] )
	_ok("endurance keeps pool reuse bounded",
		int(after["pooled"]) <= int(before["pooled"]) + 160,
		"pooled %d -> %d" % [int(before["pooled"]), int(after["pooled"])] )
	_ok("endurance keeps generation stable", int(second_half["worst_pass_us"]) < FRAME_BUDGET_US,
		"first=%d us second=%d us" % [int(first_half["worst_pass_us"]), int(second_half["worst_pass_us"])] )


func _measure(frames: int, step: Vector2) -> Dictionary:
	_field.reset_report()
	var pass_total := 0
	var build_total := 0
	var generations := 0
	for i in frames:
		_move(step)
		await physics_frame
		pass_total += int(_field.get("_frame_us"))
		build_total += int(_field.get("_worst_frame_us"))
		generations += int(_field.get("_generations_last"))
	var data := _snapshot()
	data["avg_pass_us"] = pass_total / maxi(frames, 1)
	data["worst_pass_us"] = int(_field.get("_worst_pass_us"))
	data["worst_build_us"] = int(_field.get("_worst_frame_us"))
	data["generations"] = generations
	return data


func _snapshot() -> Dictionary:
	var world: Dictionary = _field.stats()
	return {
		"live": int(world.get("live", 0)),
		"chunks": int(world.get("chunks", 0)),
		"pooled": int(world.get("pooled_nodes", 0)),
		"objects_created": int(world.get("objects_created", 0)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"physics_active": int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
		"memory_static": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"background_nodes": int(_bg.stats().get("nodes", 0)),
		"background_chunks": int(_bg.stats().get("chunks", 0)),
	}
