extends SceneTree

## Sub-stage 1.2 verification: the engine plant, in the spec's own test numbers.
## Run: godot --headless --path . --script tests/stage1_2_engines_test.gd
##
## 1  main engine      2  inertia and fade   3  braking engines
## 4  manoeuvring      5  rotation verniers  6  combined control
## 7  smoothness       8  endurance
## plus the parameter contract (spec 11), the nozzle anchors (spec 9) and the
## centralised readout (spec 3).
##
## The rule this suite exists to hold is spec 4's: the flight model already
## computes the acceleration from W, so the plant must hand it power and never add
## a second one. Every force assertion here is a superposition test - burn the
## groups alone, burn them together, and the combined hull must be the sum of the
## parts. Anything else is double application wearing a different name.
##
## Powers and fades are read from the plant and the visuals layer, not from the
## input state, so a jet that lies about a burn fails here instead of looking fine
## on screen. The pixels are covered by tests/stage1_flight_screens.gd.

const MAP := "res://scenes/test/TestControlMap.tscn"
## Wall-clock budget, measured in physics steps so a rate change cannot fake a
## hang.
const PHASE_STEPS := 6000
## The clear corridor the burns are flown in.
const CORRIDOR := Vector2(0, 1000)

var _ship: ShipController
var _plant: EngineController
var _fx: EngineVisuals
var _params: ShipEngineParameters
var _rocks: Array = []
var _homes := {}
var _checks := 0
var _failed := 0
var _phase := "boot"
var _steps_at_start := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	_ship = scene.get_node("Ship") as ShipController
	_plant = _ship.engines
	_fx = _ship.get_node("EngineFx") as EngineVisuals
	_params = _ship.settings()
	_rocks = get_nodes_in_group("obstacle")
	for rock in _rocks:
		_homes[rock] = [rock.global_position, rock.global_rotation]
	await process_frame
	await physics_frame

	_beat("architecture")
	_test_architecture()
	_test_parameters()
	_test_anchors()
	await _test_1_main_engine()
	await _test_2_inertia_and_fade()
	await _test_3_braking()
	await _test_4_manoeuvring()
	await _test_5_rotation()
	await _test_6_combined()
	await _test_7_smoothness()
	await _test_8_endurance()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


# ------------------------------------------------------------------ plumbing --

func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _beat(tag: String, steps := PHASE_STEPS) -> void:
	_phase = tag
	_steps_at_start = Engine.get_physics_frames()
	print("-- %s   physics=%d" % [tag, Engine.get_physics_frames()])


func _step() -> void:
	await physics_frame
	if Engine.get_physics_frames() - _steps_at_start > PHASE_STEPS:
		print("WATCHDOG  stuck in phase '", _phase, "'")
		quit(3)


func _wait(frames: int) -> void:
	for i in frames:
		await _step()


func _release_all() -> void:
	for a in ["thrust_forward", "thrust_backward", "turn_left", "turn_right",
			"strafe_left", "strafe_right"]:
		Input.action_release(a)


## Park the hull dead still in the corridor. The stones are lifted out for the
## whole suite: this is about what the plant delivers, and a contact would answer
## a different question.
func _park(heading := 0.0) -> void:
	_release_all()
	_clear_the_arena()
	_ship.movement_enabled = true
	var at := CORRIDOR
	_place(at, heading)
	await process_frame
	# A parked ship is a cold ship: the ramps have to start from zero, or the first
	# frames of a phase inherit the burn of the one before it and the ramp being
	# measured is not the one being asserted.
	var guard := 0
	while guard < 400 and (_plant.total_load() > 0.0
			or _ship.commanded_acceleration.length() > 0.0001):
		await _step()
		guard += 1
	# One step past the placement. A `rotation` or `global_position` written on a
	# RigidBody2D is a request the server takes on its own clock, and a phase that
	# reads the hull before that step gets the previous phase's attitude back.
	# A transform written on a RigidBody2D from inside a physics callback is
	# deferred: the server takes it on its own clock, and a step that begins before
	# that lands the hull back where the last phase left it. So the placement is
	# re-asserted and only trusted once it has survived a full step - otherwise
	# every phase would start from somebody else's position and attitude.
	var settle := 0
	while settle < 30:
		_place(at, heading)
		await _step()
		settle += 1
		if _parked(at, heading):
			break
	if not _parked(at, heading):
		print("   [park] NOT SETTLED after %d tries: pos=%s rot=%.3f v=%s" % [settle,
			str(_ship.global_position), _ship.rotation, str(_ship.linear_velocity)])


## Bring the hull down with whichever lever opposes its motion this frame. S burns
## off forward and sideways flight; a ship already running tail-first needs W,
## because for it S means "back up further" - the mode rule of 1.1 working as
## specified, not a brake that failed to bite.
func _brake_to_a_stop() -> void:
	var settle := 0
	while settle < 600 and _ship.speed() > 8.0:
		var tail_first := _ship.forward_speed() < 0.0 and absf(_ship.forward_speed()) > _ship.speed() * 0.5
		if tail_first:
			Input.action_release("thrust_backward")
			Input.action_press("thrust_forward")
		else:
			Input.action_release("thrust_forward")
			Input.action_press("thrust_backward")
		await _step()
		settle += 1
	_release_all()


func _place(at: Vector2, heading: float) -> void:
	_ship.rotation = heading
	_ship.angular_velocity = 0.0
	_ship.linear_velocity = Vector2.ZERO
	_ship.global_position = at


## Does the body agree with the placement yet?
func _parked(at: Vector2, heading: float) -> bool:
	return (_ship.global_position.distance_to(at) < 0.5
		and absf(wrapf(_ship.rotation - heading, -PI, PI)) < 0.001
		and _ship.linear_velocity.length() < 0.5
		and absf(_ship.angular_velocity) < 0.001)


func _clear_the_arena() -> void:
	for rock in _rocks:
		rock.global_position = Vector2(0, 38000.0)


func _restore_the_arena() -> void:
	for rock in _rocks:
		var home: Array = _homes[rock]
		rock.global_position = home[0]
		rock.global_rotation = home[1]


## Frames the plant needs to reach full authority on a group. Read off the
## parameter rather than counted by hand, so retuning moves the test with it.
func _frames_for(seconds: float) -> int:
	return maxi(int(ceil(seconds * 60.0)) + 1, 1)


func _jets_of(group: String) -> Array:
	var out := []
	for anchor in _fx.anchors(group):
		out.append(anchor)
	return out


func _shown(group: String) -> float:
	var brightest := 0.0
	for anchor in _jets_of(group):
		brightest = maxf(brightest, _fx.shown(anchor))
	return brightest


# ------------------------------------------------------- 0. the parts of it ----

func _test_architecture() -> void:
	_ok("the plant is a node of the ship, not a block inside the flight model",
		_plant != null and _plant is EngineController and _plant.get_parent() == _ship,
		str(_plant))
	_ok("the visuals layer reads the plant and nothing else",
		_fx != null and _fx.controller == _plant and _fx.get_parent() == _ship,
		"controller=%s" % str(_fx.controller))
	_ok("the flight model still owns the forces: the plant has no apply_* of its own",
		not _plant.has_method("apply_force") and not _plant.has_method("apply_impulse")
		and _plant.get_child_count() == 0, "%d children" % _plant.get_child_count())
	_ok("no nozzle is a physical body",
		_fx.get_child_count() > 0 and _collision_children(_ship) == 11,
		"%d anchors, still %d hull shapes on the body"
		% [_fx.get_child_count(), _collision_children(_ship)])
	_ok("the plant answers the questions other systems need",
		_plant.has_method("power") and _plant.has_method("is_active")
		and _plant.has_method("thrust_direction") and _plant.has_method("total_load")
		and _plant.has_method("report"), "power/is_active/thrust_direction/total_load/report")
	for g in EngineController.Group.values():
		_ok("group %s is interrogable" % str(g), _plant.has_method("power") and _plant.power(g) == 0.0 and not _plant.is_active(g),
			"%.2f, active=%s" % [_plant.power(g), str(_plant.is_active(g))])


## The parameter contract from spec 11: fourteen names, all on one resource, all
## in the inspector.
func _test_parameters() -> void:
	_beat("parameters")
	var names := ["main_engine_max_power", "main_engine_response_time",
		"main_engine_shutdown_time", "braking_engine_max_power",
		"braking_engine_response_time", "maneuvering_engine_power",
		"maneuvering_engine_response_time", "max_lateral_speed",
		"rotation_engine_power", "rotation_engine_response_time",
		"engine_glow_intensity", "engine_effect_fade_time", "engine_particles_amount",
		"engine_effect_scale"]
	var editable := _editable_names(_params)
	for name in names:
		var value: Variant = _params.get(name)
		_ok("%s is on the resource and editable" % name,
			editable.has(name) and value != null, "%s = %s" % [name, str(value)])
	_ok("the ship runs on the resource the scene assigns",
		_params.resource_path.ends_with("engine_parameters.tres"), _params.resource_path)
	_ok("the plant reads that same resource", _plant.settings() == _params,
			"%s" % _plant.settings())
	_ok("the lateral thrusters are weaker than the engine they cannot replace",
		_params.maneuvering_engine_power < _ship.forward_acceleration,
		"%.0f of %.0f px/s^2" % [_params.maneuvering_engine_power,
		_ship.forward_acceleration])
	_ok("authority ceilings are shares, not accelerations",
		_params.main_engine_max_power <= 1.0 and _params.braking_engine_max_power <= 1.0
		and _params.rotation_engine_power <= 1.0,
		"%.2f / %.2f / %.2f" % [_params.main_engine_max_power,
		_params.braking_engine_max_power, _params.rotation_engine_power])
	_ok("every ramp is a real time, not a frame count",
		_params.main_engine_response_time > 0.0
		and _params.braking_engine_response_time > 0.0
		and _params.maneuvering_engine_response_time > 0.0
		and _params.rotation_engine_response_time > 0.0
		and _params.main_engine_shutdown_time > 0.0,
		"main %.2f s up / %.2f s down, brake %.2f s, strafe %.2f s, spin %.2f s"
		% [_params.main_engine_response_time, _params.main_engine_shutdown_time,
		_params.braking_engine_response_time, _params.maneuvering_engine_response_time,
		_params.rotation_engine_response_time])
	_ok("the particle budget is small and stated once",
		_params.engine_particles_amount <= 24,
		"%d per jet across %d anchors" % [_params.engine_particles_amount,
		_fx.get_child_count()])


func _editable_names(node: Object) -> Array[String]:
	var out: Array[String] = []
	for p in node.get_property_list():
		var name := String(p.name)
		if bool(p.usage & PROPERTY_USAGE_EDITOR) and bool(p.usage & PROPERTY_USAGE_STORAGE) \
				and not name.begins_with("_"):
			out.append(name)
	return out


## Spec 9: the stations are nodes, and the code knows no coordinates.
func _test_anchors() -> void:
	_beat("nozzle anchors")
	var counts := {}
	for anchor in _fx.anchors():
		counts[anchor.thruster] = int(counts.get(anchor.thruster, 0)) + 1
	_ok("every group has its own stations",
		int(counts.get("main", 0)) >= 1 and int(counts.get("brake", 0)) >= 2
		and int(counts.get("strafe", 0)) >= 2 and int(counts.get("rotation", 0)) >= 2,
		str(counts))
	_ok("a station is a Marker2D carrying a jet, not a hand-placed sprite",
		_fx.anchors()[0] is Marker2D and _fx.anchors()[0].get_child_count() == 1,
		"%s -> %s" % [_fx.anchors()[0].name, _fx.anchors()[0].get_child(0).name])
	var spins := {}
	for anchor in _fx.anchors("rotation"):
		spins[anchor.spin] = int(spins.get(anchor.spin, 0)) + 1
	_ok("the yaw verniers cover both directions of the turn",
		int(spins.get(1, 0)) >= 2 and int(spins.get(-1, 0)) >= 2, str(spins))
	var aimed := 0
	for anchor in _fx.anchors("brake"):
		if anchor.thrust_local.length_squared() > 0.9:
			aimed += 1
	_ok("each brake station states a real push direction",
		aimed == _fx.anchors("brake").size(), "%d of %d unit-aimed"
		% [aimed, _fx.anchors("brake").size()])
	# the point of anchors: move one and the picture follows without a code change
	var anchor: EngineNozzle = _fx.anchors("main")[0]
	var was := anchor.position
	anchor.position = was + Vector2(0, 40.0)
	await _step()
	await _step()
	_ok("a station moved in the scene moves its jet with it",
		anchor.get_child(0).global_position == anchor.global_position
		and absf(anchor.get_child(0).global_position.y - 1040.0) < 0.5,
		"jet at %s after the station moved to %s" % [
		str(anchor.get_child(0).global_position), str(anchor.global_position)])
	anchor.position = was
	# and a second main nozzle is supported without touching anything
	var spare := EngineNozzle.new()
	spare.thruster = "main"
	spare.name = "MainSpare"
	var jet: EngineJet = load("res://scenes/ship/NozzleJet.tscn").instantiate()
	spare.add_child(jet)
	_fx.add_child(spare)
	# A station created at runtime has to be taken in the same way the scene's own
	# are: the layer faces it and adopts the parameters, so a spare nozzle is not a
	# second code path.
	_fx.adopt(spare)
	await _step()
	_ok("the plant supports more than one main nozzle",
		_fx.anchors("main").size() == 2 and jet.parameters == _params,
		"%d main stations, spare wired to the same parameters"
		% _fx.anchors("main").size())
	_fx.remove_child(spare)
	spare.queue_free()


# --------------------------------------------------- test 1. the main engine ---

func _test_1_main_engine() -> void:
	_beat("test 1 main engine")
	await _park()
	_ok("a cold plant is dark", _plant.main_power == 0.0 and _shown("main") == 0.0,
		"power=%.2f shown=%.2f" % [_plant.main_power, _shown("main")])
	# drag off, so one frame's change is one frame's thrust and nothing else
	var was_drag := _ship.linear_drag
	_ship.linear_drag = 0.0
	Input.action_press("thrust_forward")
	await _step()
	var first := _ship.commanded_acceleration.length()
	_ok("the engine comes up on a ramp, not a step",
		first < _ship.forward_acceleration * 0.5,
		"first frame %.0f of %.0f px/s^2" % [first, _ship.forward_acceleration])
	_ok("and the plant is the thing that is soft, not the physics",
		_plant.main_power < 0.5 and _plant.main_power > 0.0,
		"power=%.2f after one frame" % _plant.main_power)
	await _wait(_frames_for(_params.main_engine_response_time))
	var full := _ship.commanded_acceleration.length()
	_ok("at full power the hull sees exactly the flight model's acceleration",
		absf(full - _ship.forward_acceleration * _params.main_engine_max_power) < 1.0,
		"%.1f px/s^2 of %.0f x %.2f authority" % [full, _ship.forward_acceleration,
		_params.main_engine_max_power])
	_ok("one frame's gain is that acceleration over that clock",
		absf(_ship.forward_speed() - _ship.forward_acceleration
		* _params.main_engine_response_time * 0.5) < 40.0,
		"%.0f px/s after the ramp" % _ship.forward_speed())
	# the ceiling has to be a real multiplier, not a label
	_params.main_engine_max_power = 0.5
	await _wait(30)
	_ok("main_engine_max_power throttles the force, not only the picture",
		absf(_ship.commanded_acceleration.length()
		- _ship.forward_acceleration * 0.5) < 1.0,
		"%.0f px/s^2 at 0.5 authority" % _ship.commanded_acceleration.length())
	_params.main_engine_max_power = 1.0
	_ship.linear_drag = was_drag
	_ok("the burn is named and aimed", _plant.is_active(EngineController.Group.MAIN)
		and _plant.thrust_direction_local().dot(_ship.forward()) > 0.999,
		"load=%.2f thrust=%s" % [_plant.total_load(),
		str(_plant.thrust_direction_local())])
	# and the nozzles follow the power
	await _wait(60)
	var main_anchor: EngineNozzle = _fx.anchors("main")[0]
	var jet: EngineJet = main_anchor.get_child(0)
	_ok("the main nozzle is lit and stretched to the power",
		jet.visible and _fx.shown(main_anchor) > 0.9
		and jet.plume.scale.x > 1.5,
		"shown=%.2f plume scale=%s" % [_fx.shown(main_anchor), str(jet.plume.scale)])
	Input.action_release("thrust_forward")
	await _park()


# ---------------------------------------------- test 2. inertia and the fade ---

func _test_2_inertia_and_fade() -> void:
	_beat("test 2 inertia and fade")
	await _park()
	Input.action_press("thrust_forward")
	await _wait(180)
	Input.action_release("thrust_forward")
	_ok("letting go of W does not cut the engine", _plant.main_power > 0.9,
		"power=%.2f on the frame the key came off" % _plant.main_power)
	await _wait(_frames_for(_params.main_engine_shutdown_time))
	_ok("and it dies out over the shutdown time", _plant.main_power == 0.0,
		"power=%.2f after %.2f s" % [_plant.main_power,
		_params.main_engine_shutdown_time])
	var fading := _shown("main")
	_ok("the flame is gone once its own fade is done", fading == 0.0,
		"shown=%.2f" % fading)
	var coasting := _ship.speed()
	_ok("the hull kept everything it earned", coasting > _ship.max_forward_speed * 0.8,
		"%.0f px/s with the engine cold" % coasting)
	_ok("nothing is burning while it coasts",
		_plant.total_load() == 0.0 and _ship.commanded_acceleration.length() < 0.01,
		"load=%.2f, commanded=%.4f px/s^2" % [_plant.total_load(),
		_ship.commanded_acceleration.length()])
	var before := _ship.speed()
	await _wait(60)
	_ok("and the only thing taking it back is the void",
		absf(_ship.speed() - before * exp(-_ship.linear_drag)) < before * 0.01 + 1.0,
		"%.0f -> %.0f px/s over 1 s (the glide promises %.0f)"
		% [before, _ship.speed(), before * exp(-_ship.linear_drag)])
	# the fade is a ramp: sample it, do not trust that it finished
	await _park()
	Input.action_press("thrust_forward")
	await _wait(120)
	Input.action_release("thrust_forward")
	var steps := 0
	var series := []
	while _plant.main_power > 0.0 and steps < 120:
		await _step()
		steps += 1
		series.append(_plant.main_power)
	var drops := true
	for i in range(1, series.size()):
		if series[i] > series[i - 1] + 1e-6:
			drops = false
	_ok("the power walks down monotonically, it does not fall",
		drops and series.size() >= 2, "%d frames of fade" % series.size())
	await _park()


# ------------------------------------------------ test 3. the braking engines --

func _test_3_braking() -> void:
	_beat("test 3 braking engines")
	# spec 5's own example: the hull turned, the speed still going somewhere else
	await _park(0.0)
	Input.action_press("thrust_forward")
	await _wait(150)
	Input.action_release("thrust_forward")
	Input.action_press("turn_left")
	var guard := 0
	while guard < 140 and absf(wrapf(_ship.rotation, -PI, PI)) < PI * 0.5:
		await _step()
		guard += 1
	Input.action_release("turn_left")
	var path := _ship.linear_velocity.normalized()
	_ok("the hull is 90 deg off its own path before the brakes are touched",
		absf(_ship.forward().dot(path)) < 0.05,
		"nose and path %.0f deg apart" % rad_to_deg(absf(
		_ship.forward().angle_to(path))))
	Input.action_press("thrust_backward")
	await _wait(_frames_for(_params.braking_engine_response_time))
	_ok("S lit the braking group and not the astern one",
		_plant.brake_power > 0.95 and _plant.astern_power == 0.0,
		"brake=%.2f astern=%.2f" % [_plant.brake_power, _plant.astern_power])
	_ok("the burn is named BRAKING", _ship.movement_mode == ShipController.Mode.BRAKING,
		_ship.mode_name())
	_ok("the plant's push is against the velocity, not the nose",
		_ship.thrust_direction().dot(-_ship.linear_velocity.normalized()) > 0.999
		and absf(_ship.thrust_direction().dot(_ship.forward())) < 0.7,
		"push=%s against velocity=%s, the nose is %s" % [str(_ship.thrust_direction()),
		str(_ship.linear_velocity.normalized()), str(_ship.forward())])
	# which nozzles are lit is the whole claim of spec 5's visual requirement
	var lit := []
	var dark := []
	for anchor in _fx.anchors("brake"):
		if _fx.shown(anchor) > 0.5:
			lit.append(anchor.name)
		elif _fx.shown(anchor) < 0.05:
			dark.append(anchor.name)
	_ok("the lit brake nozzles are the ones aimed at the real push",
		not lit.is_empty(), "%s lit, %s dark" % [str(lit), str(dark)])
	var best := 0.0
	for anchor in _fx.anchors("brake"):
		if anchor.name in lit:
			best = maxf(best, anchor.thrust_local.dot(
				_plant.thrust_direction_local()))
	_ok("none of them is fighting the direction", best > 0.5,
		"worst lit aim %.2f" % best)
	var was := _ship.speed()
	await _wait(30)
	_ok("and the speed is actually coming down", _ship.speed() < was,
		"%.0f -> %.0f px/s" % [was, _ship.speed()])
	# the handover the spec insists on: brake first, then reverse, never a fight
	guard = 0
	while guard < 300 and _ship.speed() > _ship.velocity_stop_threshold:
		await _step()
		guard += 1
	_ok("braking hands over to astern instead of arguing with it",
		(_plant.brake_power > 0.0) != (_plant.astern_power > 0.0)
		or (_plant.brake_power == 0.0 and _plant.astern_power == 0.0),
		"brake=%.2f astern=%.2f at %.0f px/s" % [_plant.brake_power,
		_plant.astern_power, _ship.speed()])
	await _wait(_frames_for(_params.braking_engine_response_time) + 20)
	_ok("once there is nothing left to brake the retro group is dark",
		_plant.brake_power == 0.0 and _plant.astern_power > 0.5,
		"brake=%.2f astern=%.2f" % [_plant.brake_power, _plant.astern_power])
	Input.action_release("thrust_backward")
	await _wait(30)
	_ok("and releasing S puts the whole lever out",
		_plant.brake_power == 0.0 and _plant.astern_power == 0.0,
		"%.2f / %.2f" % [_plant.brake_power, _plant.astern_power])
	await _park()


# ------------------------------------------------ test 4. manoeuvring engines --

func _test_4_manoeuvring() -> void:
	_beat("test 4 manoeuvring")
	await _park(0.0)
	var heading := _ship.rotation
	var starboard := _ship.starboard()
	Input.action_press("strafe_right")
	await _wait(_frames_for(_params.maneuvering_engine_response_time))
	starboard = _ship.starboard()
	_ok("E is a signed demand toward starboard",
		absf(_plant.strafe_demand() - 1.0) < 0.01, "%.2f" % _plant.strafe_demand())
	_ok("E pushes across the hull, not along it",
		absf(_ship.drift_speed()) > 1.0 and absf(_ship.forward_speed()) < 1.0,
		"across=%.1f, along=%.1f px/s" % [_ship.drift_speed(), _ship.forward_speed()])
	var was := _ship.rotation
	var slid := Vector2.ZERO
	await _wait(60)
	_ok("sideways flight does not turn the ship",
		absf(_ship.rotation - was) < 1e-6 and _ship.angular_velocity == 0.0,
		"rotation moved %.6f rad" % (_ship.rotation - was))
	_ok("and the hull still points where it was pointed",
		absf(_ship.rotation - heading) < 1e-6, "%.4f rad" % _ship.rotation)
	slid = _ship.global_position - CORRIDOR
	_ok("the hull really slid across the sky",
		absf(slid.dot(starboard)) > 40.0 and absf(slid.dot(_ship.forward())) < 10.0,
		"%.0f px across, %.0f px along the nose" % [slid.dot(starboard),
		slid.dot(_ship.forward())])
	_ok("exactly one manoeuvring nozzle is lit, and it pushes the way the hull slid",
		_lit_names("strafe").size() == 1
		and _anchor(_shown_lit_name("strafe")).thrust_world()
		.dot(_ship.linear_velocity.normalized()) > 0.99,
		"%s lit, push %.2f of the flight direction" % [_shown_lit_name("strafe"),
		_anchor(_shown_lit_name("strafe")).thrust_world()
		.dot(_ship.linear_velocity.normalized())])
	Input.action_release("strafe_right")
	await _wait(30)
	_ok("releasing the lever keeps the lateral speed it earned",
		absf(_ship.drift_speed()) > _params.max_lateral_speed * 0.6,
		"%.0f px/s across with nothing pressed" % _ship.drift_speed())
	var drift := _ship.drift_speed()
	await _wait(60)
	_ok("and that drift decays like any other speed",
		absf(_ship.drift_speed()) < absf(drift) and absf(_ship.drift_speed())
		> absf(drift) * exp(-_ship.linear_drag * 1.0) * 0.95,
		"%.0f -> %.0f px/s over 1 s" % [drift, _ship.drift_speed()])
	# the ceiling: hold it long enough and the thrusters stop adding
	Input.action_press("strafe_right")
	var guard := 0
	while guard < 400 and absf(_ship.drift_speed()) < _params.max_lateral_speed * 0.99:
		await _step()
		guard += 1
	_ok("the lateral ceiling is the exported number",
		absf(_ship.drift_speed() - _params.max_lateral_speed) < 3.0,
		"%.1f of %.0f px/s" % [_ship.drift_speed(), _params.max_lateral_speed])
	Input.action_release("strafe_right")
	await _wait(20)
	# Q is the mirror image, and the port nozzle is the one that answers
	await _park(0.0)
	Input.action_press("strafe_left")
	await _wait(60)
	_ok("Q pushes to port and lights the nozzle that pushes it",
		_ship.drift_speed() < -10.0 and _lit_names("strafe").size() == 1
		and _anchor(_shown_lit_name("strafe")).thrust_world()
		.dot(_ship.linear_velocity.normalized()) > 0.99,
		"across=%.0f px/s, %s lit" % [_ship.drift_speed(), _shown_lit_name("strafe")])
	_ok("the manoeuvring group is a share of the plant's load",
		absf(_plant.total_load() - 1.0) < 0.05, "%.2f" % _plant.total_load())
	Input.action_release("strafe_left")
	await _park()


## The brightest nozzle of a group - which is how the tests ask "which one is lit"
## without reaching into the layer's internals.
func _anchor(name: String) -> EngineNozzle:
	for anchor in _fx.anchors():
		if String(anchor.name) == name:
			return anchor
	return null


func _shown_lit_name(group: String) -> String:
	var best := 0.0
	var name := ""
	for anchor in _fx.anchors(group):
		if _fx.shown(anchor) > best:
			best = _fx.shown(anchor)
			name = String(anchor.name)
	return name if best > 0.5 else ""


# -------------------------------------------------- test 5. rotation verniers --

func _test_5_rotation() -> void:
	_beat("test 5 rotation")
	await _park(0.0)
	Input.action_press("turn_left")
	await _wait(_frames_for(_params.rotation_engine_response_time))
	_ok("A is a signed demand for the counter-clockwise pair",
		absf(_plant.rotation_demand() + 1.0) < 0.01, "%.2f" % _plant.rotation_demand())
	var lit := _lit_names("rotation")
	_ok("exactly the counter-clockwise verniers are burning",
		lit.size() == 2 and lit.count("SpinCounterPort") == 1
		and lit.count("SpinCounterStarboard") == 1, str(lit))
	_ok("a couple is not reported as a push",
		absf(_plant.thrust_direction_local().x) < 0.05
		and absf(_plant.thrust_direction_local().y) < 0.05,
		"thrust_local=%s from a yaw-only burn" % str(_plant.thrust_direction_local()))
	await _wait(_frames_for(_ship.max_angular_speed / _ship.angular_acceleration) + 10)
	var yaw := _ship.angular_velocity
	_ok("and the hull reaches the rate the flight model promised",
		yaw < -_ship.max_angular_speed * 0.99, "%.2f rad/s" % yaw)
	# the switch of direction: the old pair must fade, not snap off
	Input.action_release("turn_left")
	Input.action_press("turn_right")
	await _step()
	var still := _lit_names("rotation")
	_ok("the previous pair is still alight on the frame the rudder flips",
		still.size() == 2, "%s still showing" % str(still))
	await _wait(30)
	var now := _lit_names("rotation")
	_ok("and the new pair has taken over",
		now.size() == 2 and now.count("SpinClockwisePort") == 1
		and now.count("SpinClockwiseStarboard") == 1, str(now))
	_ok("the yaw rate went through zero rather than jumping",
		_ship.angular_velocity > 0.0, "%.2f rad/s on the new rudder"
		% _ship.angular_velocity)
	Input.action_release("turn_right")
	await _wait(60)
	_ok("a released rudder leaves no nozzle lit",
		_lit_names("rotation").is_empty() and _plant.rotation_power == 0.0,
		str(_lit_names("rotation")))
	await _park()


func _lit_names(group: String) -> Array[String]:
	var out: Array[String] = []
	for anchor in _fx.anchors(group):
		if _fx.shown(anchor) > 0.5:
			out.append(String(anchor.name))
	return out


# ------------------------------------------------- test 6. combined control ----

func _test_6_combined() -> void:
	_beat("test 6 combined control")
	var was_drag := _ship.linear_drag
	var was_lateral := _params.max_lateral_speed
	_ship.linear_drag = 0.0
	_params.max_lateral_speed = 4000.0

	# three single-lever burns, so the combined one has something to add up to
	# Burn each linear group alone, then both together, and compare the world
	# velocity: superposition is what "the groups sum their thrust" has to mean,
	# and it is also the proof that no group is applying its acceleration twice.
	await _park(0.0)
	Input.action_press("thrust_forward")
	await _wait(150)
	var alone_main := _ship.linear_velocity
	Input.action_release("thrust_forward")

	await _park(0.0)
	Input.action_press("strafe_right")
	await _wait(150)
	var alone_strafe := _ship.linear_velocity
	var alone_along := _ship.forward_speed()
	Input.action_release("strafe_right")

	await _park(0.0)
	Input.action_press("turn_left")
	await _wait(150)
	var alone_yaw := _ship.angular_velocity
	Input.action_release("turn_left")

	await _park(0.0)
	Input.action_press("thrust_forward")
	Input.action_press("strafe_right")
	await _wait(150)
	var sum := alone_main + alone_strafe
	var together := _ship.linear_velocity
	_ok("W and E together are the vector sum of W and E alone",
		together.distance_to(sum) < sum.length() * 0.02,
		"together (%.0f, %.0f), the parts add to (%.0f, %.0f), off by %.1f px/s"
		% [together.x, together.y, sum.x, sum.y, together.distance_to(sum)])
	_ok("E alone put nothing along the nose", absf(alone_along) < 1.0,
		"%.1f px/s along" % alone_along)
	# The push is a statement about this frame's force, not about the speed the
	# ship has been collecting: with two groups of different authority and
	# different ramps, the velocity is the integral and points wherever the integral
	# says. What has to hold is that the push names both burning groups.
	_ok("the plant's push names both burning groups, not just the engine",
		absf(_ship.thrust_direction().dot(_ship.forward()) - 0.707) < 0.05
		and absf(_ship.thrust_direction().dot(_ship.starboard()) - 0.707) < 0.05,
		"push %s with main=%.2f strafe=%.2f" % [str(_ship.thrust_direction()),
		_plant.main_power, absf(_plant.strafe_demand())])
	Input.action_release("thrust_forward")
	Input.action_release("strafe_right")

	await _park(0.0)
	Input.action_press("thrust_forward")
	Input.action_press("strafe_right")
	Input.action_press("turn_left")
	await _wait(150)
	_ok("and the rudder does not touch what the linear groups delivered",
		absf(_ship.angular_velocity - alone_yaw) < 0.02,
		"yaw %.2f with two other groups burning, %.2f alone"
		% [_ship.angular_velocity, alone_yaw])
	_ok("three groups burn as three loads, not one",
		absf(_plant.total_load() - 3.0) < 0.1, "%.2f" % _plant.total_load())
	_ok("the push is the vector sum of what is burning",
		absf(_plant.thrust_direction_local().dot(Vector2(1.0, 1.0).normalized())) > 0.99,
		"thrust_local=%s" % str(_plant.thrust_direction_local()))
	Input.action_release("thrust_forward")
	Input.action_release("strafe_right")
	Input.action_release("turn_left")

	# W + S at once: the two levers fight, and the hull must not resonate
	await _park(0.0)
	Input.action_press("thrust_forward")
	await _wait(180)
	var both_before := _ship.speed()
	Input.action_press("thrust_backward")
	var jumps := 0
	var was := _ship.linear_velocity
	for i in 60:
		await _step()
		if (_ship.linear_velocity - was).length() > _ship.braking_acceleration / 60.0 * 1.6:
			jumps += 1
		was = _ship.linear_velocity
	Input.action_release("thrust_backward")
	Input.action_release("thrust_forward")
	_ok("both levers together are a wash, not a resonance",
		jumps == 0 and _ship.speed() < both_before,
		"%.0f -> %.0f px/s, %d steps over the braking authority"
		% [both_before, _ship.speed(), jumps])

	# all five at once, and nothing may break
	await _park(0.0)
	Input.action_press("thrust_forward")
	Input.action_press("strafe_left")
	Input.action_press("turn_right")
	var broken := 0
	for i in 120:
		await _step()
		if not (_finite(_ship.global_position) and _finite(_ship.linear_velocity)):
			broken += 1
	_ok("every group at once is still a ship",
		broken == 0 and _plant.main_power > 0.5 and _plant.brake_power < 0.01
		and _plant.strafe_demand() < -0.5 and _plant.rotation_demand() > 0.5,
		"main=%.2f brake=%.2f strafe=%.2f spin=%.2f, %d broken frames"
		% [_plant.main_power, _plant.brake_power, _plant.strafe_demand(),
		_plant.rotation_demand(), broken])
	_release_all()
	_params.max_lateral_speed = was_lateral
	_ship.linear_drag = was_drag
	await _park()


# ----------------------------------------------------- test 7. smoothness ------

func _test_7_smoothness() -> void:
	_beat("test 7 smoothness")
	await _park(0.0)
	var fade := maxf(_params.engine_effect_fade_time, 0.001)
	var worst := 0.0
	var frames := 0
	_previous.clear()
	var order := [["thrust_forward"], ["strafe_right"], ["turn_left"],
		["thrust_forward", "thrust_backward"], [], ["strafe_left"], ["turn_right"],
		["thrust_backward"]]
	while frames < 700:
		if frames % 50 == 0:
			_release_all()
			for a in order[int(frames / 50.0) % order.size()]:
				Input.action_press(a)
		await _step()
		frames += 1
		for anchor in _fx.anchors():
			worst = maxf(worst, absf(_fx.shown(anchor)))
		worst = maxf(worst, _biggest_jet_step())
	_release_all()
	_ok("no jet ever jumps faster than the fade allows",
		worst <= 60.0 * fade * 1.25 + 0.02,
		"biggest one-frame change of shown power=%.3f, the fade allows %.3f"
		% [worst, 60.0 * fade])
	_previous.clear()
	# a group that stops must be seen to dim, not to vanish
	await _park(0.0)
	Input.action_press("strafe_right")
	await _wait(60)
	Input.action_release("strafe_right")
	await _step()
	var after_one := _shown("strafe")
	_ok("a released group is still glowing on the next frame",
		after_one > 0.5, "%.2f" % after_one)
	var dimmed := 0
	for i in 20:
		await _step()
		if _shown("strafe") < 0.02:
			dimmed = i + 1
			break
	_ok("and it goes out over frames, not between them",
		dimmed > 1 and dimmed <= _frames_for(_params.engine_effect_fade_time) + 2,
		"%d frames of dimming" % dimmed)
	_ok("an idle ship carries no engine light at all",
		_shown("main") == 0.0 and _shown("brake") == 0.0 and _shown("strafe") == 0.0
		and _shown("rotation") == 0.0, "all groups dark")
	await _park()


## The largest one-frame change across every nozzle's shown power. Measured
## between two calls, so it is the picture's own step, not the physics'.
func _biggest_jet_step() -> float:
	var worst := 0.0
	for anchor in _fx.anchors():
		var now := _fx.shown(anchor)
		var key := anchor.get_instance_id()
		worst = maxf(worst, absf(now - float(_previous.get(key, 0.0))))
		_previous[key] = now
	return worst


var _previous := {}


# ----------------------------------------------------- test 8. endurance -------

func _test_8_endurance() -> void:
	_beat("test 8 endurance")
	await _park(0.0)
	var nodes_before := _count_nodes(_ship)
	var jets_before := _fx.get_child_count()
	var frames := 0
	var out_of_range := 0
	var fastest := 0.0
	var loads := []
	var routine := [["thrust_forward"], ["thrust_forward", "turn_left"],
		["thrust_backward"], ["thrust_backward", "strafe_right"], ["strafe_left"],
		["turn_right"], ["thrust_forward", "strafe_left", "turn_right"], [],
		["thrust_forward", "thrust_backward", "strafe_right", "turn_left"]]
	while frames < 1500:
		if frames % 25 == 0:
			_release_all()
			for a in routine[int(frames / 25.0) % routine.size()]:
				Input.action_press(a)
		await _step()
		frames += 1
		fastest = maxf(fastest, _ship.speed())
		loads.append(_plant.total_load())
		if _plant.main_power < -0.001 or _plant.main_power > 1.0001 \
				or _plant.brake_power > _params.braking_engine_max_power + 0.001 \
				or absf(_plant.strafe_demand()) > 1.0001 \
				or absf(_plant.rotation_demand()) > 1.0001:
			out_of_range += 1
	_release_all()
	_brake_to_a_stop()
	await _wait(240)
	_ok("a long flight leaves the plant inside its own numbers",
		out_of_range == 0, "%d frames out of range" % out_of_range)
	_ok("no group can exceed its authority ceiling",
		loads.max() <= 5.0 * 1.001 and loads.min() >= 0.0,
		"load %.2f .. %.2f over %d frames" % [loads.min(), loads.max(), loads.size()])
	_ok("the speed stayed inside the model",
		fastest < _ship.max_forward_speed * 1.6, "%.0f px/s peak" % fastest)
	_ok("nothing accumulated: the same anchors and the same nodes",
		_fx.get_child_count() == jets_before and _count_nodes(_ship) == nodes_before,
		"%d anchors, %d nodes (was %d)" % [_fx.get_child_count(),
		_count_nodes(_ship), nodes_before])
	_ok("and the hull is parked with everything out",
		_plant.total_load() == 0.0 and _ship.speed() == 0.0
		and _ship.angular_velocity == 0.0,
		"load=%.2f speed=%.2f" % [_plant.total_load(), _ship.speed()])
	var dark := true
	for anchor in _fx.anchors():
		if _fx.shown(anchor) > 0.0:
			dark = false
	_ok("no jet is left drawing on an idle ship", dark, "all shown powers are zero")
	# only now may the stones come home: the parking had to happen in empty sky
	_restore_the_arena()


## How many collision shapes the hull still carries - the check that the engine
## layer added pictures and not physics.
func _collision_children(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			n += 1
	return n


func _count_nodes(node: Node) -> int:
	var n := 1
	for child in node.get_children():
		n += _count_nodes(child)
	return n


func _finite(v: Vector2) -> bool:
	return is_finite(v.x) and is_finite(v.y)
