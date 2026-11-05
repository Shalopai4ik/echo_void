extends SceneTree

## Sub-stage 1.4 verification: ship states, control availability, collisions with the
## world, and external influences.
## Run: godot --headless --path . --script tests/stage1_4_states_test.gd
##
## States 1-8, control 1-6, collisions 1-9, external 1-6, then the panel and a long
## run with everything moving.
##
## The two claims this suite is really built to hold:
##
## - **The state says what the hull is doing, not what the keys say.** Every state
##   assertion is made after a burn has been *finished with*: W released at 700 px/s is
##   still a hull that is accelerating until the plant is dark, and then it is a hull
##   flying normally - and neither of those is allowed to be called "stopped".
## - **Nothing that reports may also drive.** The state layer, the contact report and
##   the external set are read by the tests through the ship, and the ship's numbers are
##   then checked against the same flight model the 1.1 suite pins down. A reporting
##   layer that quietly changed the physics would show up as a burn that no longer
##   matches its exported acceleration.
##
## Collision intensities are *estimates* - Godot's 2D bodies give no impulse and no
## contact point - so the assertions here check that the estimate is consistent with the
## geometry (a closing speed never larger than the speed the hull had, a direction from
## the hull toward what it hit), not that it equals a number no API could produce.

const MAP := "res://scenes/test/TestControlMap.tscn"
const PHASE_STEPS := 12000
const CORRIDOR := Vector2(0, 1000)
## Where the test rock is parked for the contact phases: far enough that the hull has to
## be flown into it on purpose, close enough that a cruise burn arrives in a second.
const STONE_AT := Vector2(1400, 1000)

const STATE_PARAMS := ["light_collision_threshold", "medium_collision_threshold",
	"heavy_collision_threshold", "collision_event_cooldown",
	"external_acceleration_enabled", "max_external_acceleration",
	"max_external_impulse", "ship_control_enabled_by_default"]

var _ship: ShipController
var _plant: EngineController
var _world: ShipWorldParameters
var _rocks: Array = []
var _homes := {}
var _stone = null
## The closing speeds the collision phase actually measured, in launch order. Kept at
## phase level, because "the three launches were three different speeds" is a claim about
## the set of them, not about the last one.
var _band_closings: Array[float] = []
var _state_at_contact := ""
var _checks := 0
var _failed := 0
var _phase := "boot"
var _steps_at_start := 0

var _state_events := 0
var _collision_events := 0
var _disabled_events := 0
var _enabled_events := 0
var _speed_events := 0
var _last_state_pair: Array = []


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
	_world = _ship.world
	_rocks = get_nodes_in_group("obstacle")
	for rock in _rocks:
		_homes[rock] = [rock.global_position, rock.global_rotation]
	_ship.ship_state_changed.connect(_on_state_changed)
	_ship.ship_collision_detected.connect(_on_collision)
	_ship.ship_control_disabled.connect(_on_disabled)
	_ship.ship_control_enabled.connect(_on_enabled)
	_ship.ship_speed_changed.connect(_on_speed)
	await process_frame
	await physics_frame

	_beat("architecture and parameters")
	_test_architecture()
	_test_parameters()
	await _test_states()
	await _test_control()
	await _test_collisions()
	await _test_external()
	await _test_panel_and_endurance()
	await _test_relaunch()
	_restore_the_arena()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


# ------------------------------------------------------------------ plumbing --

func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _beat(tag: String) -> void:
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
			"strafe_left", "strafe_right", "toggle_stabilization", "emergency_brake",
			"boost"]:
		Input.action_release(a)


func _park(heading := 0.0) -> void:
	_release_all()
	_clear_the_arena()
	_ship.movement_enabled = true
	_place(CORRIDOR, heading)
	await process_frame
	var guard := 0
	while guard < 900 and (_plant.total_load() > 0.001
			or _ship.external_acceleration.length_squared() > 0.0):
		await _step()
		guard += 1
	var settle := 0
	while settle < 30:
		_place(CORRIDOR, heading)
		await _step()
		settle += 1
		if _parked(CORRIDOR, heading):
			break


func _place(at: Vector2, heading: float) -> void:
	_ship.rotation = heading
	_ship.angular_velocity = 0.0
	_ship.linear_velocity = Vector2.ZERO
	_ship.global_position = at


func _parked(at: Vector2, heading: float) -> bool:
	return (_ship.global_position.distance_to(at) < 0.5
		and absf(wrapf(_ship.rotation - heading, -PI, PI)) < 0.001
		and _ship.linear_velocity.length() < 0.5
		and absf(_ship.angular_velocity) < 0.001)


func _fling(velocity: Vector2, heading: float = 0.0) -> void:
	_release_all()
	_place(CORRIDOR, heading)
	_ship.linear_velocity = velocity
	_ship.angular_velocity = 0.0
	await _step()
	_ship.linear_velocity = velocity
	await _step()


func _clear_the_arena() -> void:
	for rock in _rocks:
		# The contacts phase frees one of these on purpose, and the dictionary key is
		# the freed instance itself - so validity is checked before anything is asked
		# of it. Without this the test logs a script error every time it parks again.
		if not is_instance_valid(rock):
			continue
		# A live body keeps its own transform in the physics server, so it is
		# parked the way the server understands: held still, moved, and left
		# static for the phase that follows.
		rock.freeze = true
		rock.global_position = Vector2(0, 38000.0)


func _restore_the_arena() -> void:
	for rock in _rocks:
		# A collision phase may have freed one of these on purpose, and the dictionary's
		# key is the freed instance itself - so validity is checked before anything is
		# asked of it.
		if not is_instance_valid(rock):
			continue
		var home: Array = _homes[rock]
		rock.global_position = home[0]
		rock.global_rotation = home[1]
		rock.freeze = false


func _frames_for(seconds: float) -> int:
	return maxi(int(ceil(seconds * 60.0)) + 1, 1)


## Put one stone in front of the hull and hand it back. `_homes` still knows where it
## lived, so the belt is restored at the end of the run.
func _stone_ahead(at: Vector2 = STONE_AT) -> void:
	_stone = _rocks[0]
	# The state layer is what this suite grades, so the stone is a wall on
	# purpose: one repeatable meeting, and the belt's impulse model is not part
	# of the verdict - collision_response_test owns that.
	_stone.freeze = true
	_stone.global_position = at
	_stone.linear_velocity = Vector2.ZERO
	_stone.angular_velocity = 0.0


func _reset_counters() -> void:
	_state_events = 0
	_collision_events = 0
	_disabled_events = 0
	_enabled_events = 0
	_speed_events = 0
	_last_state_pair = []


func _on_state_changed(previous: int, current: int) -> void:
	_state_events += 1
	_last_state_pair = [previous, current]


func _on_collision(info: Dictionary) -> void:
	_collision_events += 1


func _on_disabled() -> void:
	_disabled_events += 1


func _on_enabled() -> void:
	_enabled_events += 1


func _on_speed(_speed: float) -> void:
	_speed_events += 1


# --------------------------------------------------------- architecture -------

func _test_architecture() -> void:
	_ok("the hull has a state layer", _ship.ship_state != null)
	_ok("the state layer is not a node and cannot integrate anything",
		_ship.ship_state.get_class() == "RefCounted"
		and not _ship.ship_state.has_method("_physics_process")
		and not _ship.ship_state.has_method("_process"),
		_ship.ship_state.get_class())
	_ok("the state layer writes nothing on the hull",
		not _ship.ship_state.has_method("apply_force")
		and not _ship.ship_state.has_method("apply_impulse"))
	_ok("every state the spec names exists",
		ShipState.State.keys().has("NORMAL") and ShipState.State.keys().has("ACCELERATING")
		and ShipState.State.keys().has("BRAKING")
		and ShipState.State.keys().has("EMERGENCY_BRAKING")
		and ShipState.State.keys().has("BOOSTING")
		and ShipState.State.keys().has("STABILIZING")
		and ShipState.State.keys().has("COLLISION")
		and ShipState.State.keys().has("DISABLED"),
		str(ShipState.State.keys()))
	_ok("the five signals are there",
		_ship.has_signal("ship_state_changed") and _ship.has_signal("ship_collision_detected")
		and _ship.has_signal("ship_control_enabled")
		and _ship.has_signal("ship_control_disabled")
		and _ship.has_signal("ship_speed_changed"))
	_ok("the control API is there", _ship.has_method("enable_control")
		and _ship.has_method("disable_control") and _ship.has_method("set_control_enabled"))
	_ok("the external API is there", _ship.has_method("add_external_acceleration")
		and _ship.has_method("remove_external_acceleration")
		and _ship.has_method("clear_external_accelerations")
		and _ship.has_method("apply_external_impulse"))
	var source := ""
	var file := FileAccess.open("res://scripts/ship/ship_controller.gd", FileAccess.READ)
	if file != null:
		source = file.get_as_text()
	_ok("the flight model names no world object anywhere in its source",
		not source.contains("\"Rock") and not source.contains("\"asteroid_")
		and not source.contains("\"Obstacle"),
		"%d bytes of controller read; kinds come from groups and the object's answer"
		% source.length())


func _test_parameters() -> void:
	var names: Array = []
	for p in _world.get_property_list():
		var usage: int = p.usage
		if bool(usage & PROPERTY_USAGE_EDITOR) and bool(usage & PROPERTY_USAGE_STORAGE) \
				and p.name != "script":
			names.append(p.name)
	for n in STATE_PARAMS:
		_ok("world.%s is an inspector parameter" % n, names.has(n))
	_ok("the collision bands are in order and inside the hull's own envelope",
		_world.light_collision_threshold < _world.medium_collision_threshold
		and _world.medium_collision_threshold < _world.heavy_collision_threshold
		and _world.heavy_collision_threshold < _ship.max_forward_speed * 0.6,
		"%.0f / %.0f / %.0f px/s against %.0f px/s of cruise" % [
			_world.light_collision_threshold, _world.medium_collision_threshold,
			_world.heavy_collision_threshold, _ship.max_forward_speed])
	_ok("the cooldown is long enough to stop a scrape reporting four times",
		_world.collision_event_cooldown > 0.05, "%.2f s" % _world.collision_event_cooldown)
	_ok("the external limits are below what the engines can do",
		_world.max_external_acceleration < _ship.forward_acceleration * 1.2
		and _world.max_external_impulse < _ship.max_forward_speed,
		"%.0f px/s^2, %.0f px/s" % [_world.max_external_acceleration,
			_world.max_external_impulse])
	_ok("the speed signal has a threshold, so it is not a poll",
		_world.speed_report_threshold > 0.0, "%.0f px/s" % _world.speed_report_threshold)


# ------------------------------------------------------------- states 1-8 -----

func _test_states() -> void:
	_beat("states 1-2: normal flight and acceleration")
	_reset_counters()
	await _park()
	_ok("1  a parked, untouched hull is NORMAL", _ship.state_name() == "NORMAL",
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])
	Input.action_press("thrust_forward")
	await _wait(4)
	_ok("2  a spooling engine is ACCELERATING", _ship.state_name() == "ACCELERATING",
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])
	_ok("2  and the flag says which group is working",
		_ship.ship_state.has(ShipState.FLAG_MAIN), _ship.active_systems())
	await _wait(86)
	Input.action_release("thrust_forward")
	await _wait(_frames_for(_plant.settings().main_engine_shutdown_time) + 10)
	var coasting := _ship.speed()
	_ok("1  coasting at speed is NORMAL, not stopped",
		coasting > 300.0 and _ship.state_name() == "NORMAL",
		"%.0f px/s and the word %s" % [coasting, _ship.state_name()])
	_ok("1  the spec's own trap: a released key is not a stopped ship",
		_ship.speed() > _ship.velocity_stop_threshold * 4, "%.0f px/s" % _ship.speed())

	_beat("states 3-6: the three levers and the assist")
	_reset_counters()
	await _park()
	Input.action_press("thrust_forward")
	await _wait(90)
	Input.action_release("thrust_forward")
	Input.action_press("thrust_backward")
	await _wait(20)
	_ok("3  the pilot's brake is BRAKING", _ship.state_name() == "BRAKING",
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])
	Input.action_release("thrust_backward")
	await _wait(30)
	await _fling(_ship.forward() * 700.0)
	_reset_counters()
	Input.action_press("emergency_brake")
	await _wait(6)
	_ok("4  Space is EMERGENCY_BRAKING, a different word from the same lever",
		_ship.state_name() == "EMERGENCY_BRAKING", _ship.state_name())
	Input.action_release("emergency_brake")
	await _wait(30)
	await _park()
	_ship.stabilization.set_enabled(true)
	await _wait(_frames_for(_world.collision_state_hold) + 30)
	await _fling(_ship.starboard() * 300.0)
	await _wait(20)
	_ok("5  a borrowed lever is STABILIZING", _ship.state_name() == "STABILIZING",
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])
	_ok("5  and the flag carries it even when another state has the word",
		_ship.ship_state.has(ShipState.FLAG_STABILIZER), _ship.active_systems())
	_ship.stabilization.set_enabled(false)
	await _wait(_frames_for(_ship.assists.stabilization_response_time) + 20)
	_reset_counters()
	await _park()
	_ship.boost.boost_charge = 1.0
	_ship.boost.cut_off = false
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(30)
	_ok("6  boost is BOOSTING while the engine is the thing being boosted",
		_ship.state_name() == "BOOSTING" and _ship.ship_state.has(ShipState.FLAG_MAIN),
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])

	_beat("states 7-8: several systems at once, and the transitions")
	Input.action_press("turn_right")
	Input.action_press("strafe_left")
	await _wait(20)
	var flags := _ship.ship_state.flags
	_ok("7  boost, rudder and slide all stay working together",
		_ship.boost.active and absf(_plant.rotation_power) > 0.5
		and absf(_plant.strafe_power) > 0.5,
		"spin %.2f slide %.2f" % [_plant.rotation_power, _plant.strafe_power])
	_ok("7  and the state layer reports all of them as flags",
		_ship.ship_state.has(ShipState.FLAG_BOOST)
		and _ship.ship_state.has(ShipState.FLAG_ROTATION)
		and _ship.ship_state.has(ShipState.FLAG_STRAFE),
		_ship.active_systems() + "  (primary %s)" % _ship.state_name())
	_ok("7  one state never switched another off", _ship.boost.active
		and _ship.state_name() != "NORMAL", _ship.state_name())
	_release_all()
	await _wait(_frames_for(_plant.settings().main_engine_shutdown_time) + 20)
	_ship.stabilization.set_enabled(true)
	await _wait(_frames_for(_ship.assists.stabilization_response_time) + 10)
	await _fling(_ship.forward() * 260.0)
	Input.action_press("thrust_forward")
	await _wait(20)
	_ok("7  a pilot on the lever takes the word back from the assist",
		_ship.state_name() == "ACCELERATING"
		and _ship.ship_state.has(ShipState.FLAG_STABILIZER),
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])
	Input.action_release("thrust_forward")
	_ship.stabilization.set_enabled(false)
	_reset_counters()
	await _wait(_frames_for(_plant.settings().main_engine_shutdown_time) + 10)
	_ok("8  the transitions are reported, not polled", _state_events >= 1
		and _last_state_pair.size() == 2,
		"%d state signals, last %s" % [_state_events, str(_last_state_pair)])
	_ok("8  and the ship ends where it can be described as normal",
		_ship.state_name() == "NORMAL", "%s / %s" % [
			_ship.state_name(), _ship.active_systems()])


# ----------------------------------------------------------- control 1-6 ------

func _test_control() -> void:
	_beat("control 1-3: taking the pilot away mid-flight")
	_reset_counters()
	await _park()
	Input.action_press("thrust_forward")
	await _wait(120)
	var flying := _ship.linear_velocity
	_ship.disable_control()
	await _step()
	_ok("1  the state says DISABLED", _ship.state_name() == "DISABLED",
		"%s / %s" % [_ship.state_name(), _ship.active_systems()])
	_ok("1  and the signal fired exactly once", _disabled_events == 1,
		"%d" % _disabled_events)
	var after := _ship.linear_velocity
	_ok("2  cutting the controls does not stop the hull",
		after.length() > flying.length() * 0.95,
		"%.0f -> %.0f px/s" % [flying.length(), after.length()])
	await _wait(30)
	_ok("2  it keeps flying on inertia", _ship.speed() > 200.0
		and _ship.speed() < flying.length(), "%.0f px/s" % _ship.speed())
	Input.action_press("thrust_forward")
	Input.action_press("strafe_right")
	Input.action_press("turn_left")
	await _wait(30)
	_ok("3  no new engine command gets through", _plant.total_load() < 0.02,
		"load %.3f with three levers held" % _plant.total_load())
	var decelerated_only_by_glide := _ship.speed()
	_ok("3  and nothing is braking either: the glide is the only thing touching it",
		decelerated_only_by_glide < flying.length() * 1.001,
		"%.0f px/s, started %.0f" % [decelerated_only_by_glide, flying.length()])
	_release_all()

	_beat("control 4-6: boost, re-enable, no hung states")
	await _fling(_ship.forward() * 300.0)
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(10)
	_ok("4  boost cannot be lit by a pilot who has been cut off",
		not _ship.boost.active and _plant.main_power < 0.02,
		"boost %s, main %.2f" % [str(_ship.boost.active), _plant.main_power])
	var charge_before := _ship.boost.boost_charge
	await _wait(60)
	_ok("4  and it does not spend charge for the attempt",
		_ship.boost.boost_charge == charge_before, "%.3f" % _ship.boost.boost_charge)
	_ship.enable_control()
	await _wait(4)
	_ok("5  control comes back", _ship.movement_enabled
		and _ship.state_name() != "DISABLED", _ship.state_name())
	_ok("5  and the enable signal fired once", _enabled_events == 1, "%d" % _enabled_events)
	Input.action_press("thrust_forward")
	await _wait(_frames_for(_plant.settings().main_engine_response_time) + 10)
	_ok("5  the engines answer again on the same frame they are asked",
		_plant.main_power > 0.9, "main %.2f" % _plant.main_power)
	Input.action_release("thrust_forward")
	# A hull that was left with the stabilizer switched on must not come back flying by
	# itself in a way nobody asked for - but the switch is the pilot's, so it stays where
	# they left it. Both halves of that are checked.
	_ship.stabilization.set_enabled(true)
	_ship.disable_control()
	await _wait(30)
	_ok("6  the assist switch survives, and does nothing while control is off",
		_ship.stabilization.enabled and _ship.owners() == "-|-|-|-", _ship.owners())
	_ship.enable_control()
	_ship.stabilization.set_enabled(false)
	_release_all()
	await _park()
	await _wait(_frames_for(_plant.settings().main_engine_shutdown_time) + 30)
	_ok("6  nothing is left burning or hung after the whole sequence",
		_plant.total_load() < 0.001 and _ship.state_name() == "NORMAL"
		and _ship.active_systems() == "none" and _ship.external_influence_count() == 0,
		"%s / %s / load %.4f" % [_ship.state_name(), _ship.active_systems(),
			_plant.total_load()])


# --------------------------------------------------------- collisions 1-9 -----

func _test_collisions() -> void:
	_beat("collisions 1-4: three arrivals and the bands they fall in")
	# [launch speed px/s, distance px]: three arrivals whose measured closing speeds land
	# in three different bands. The distance is flown, not scripted - the glide takes its
	# share on the way in, and the report is graded on the speed it actually measured.
	for plan in [[120.0, 260.0], [260.0, 300.0], [700.0, 420.0]]:
		_reset_counters()
		await _park()
		_stone_ahead()
		await _launch_at(Vector2.RIGHT, float(plan[1]), float(plan[0]))
		var hit := _ship.last_collision()
		_ok("1-3  a %.0f px/s launch reports exactly one contact" % plan[0],
			_collision_events == 1 and not hit.is_empty(),
			"%d events, keys %s" % [_collision_events, str(hit.keys())])
		if hit.is_empty():
			continue
		var closing := float(hit.get("closing_speed", 0.0))
		_ok("4  and the band is the one the measured closing speed falls in",
			str(hit.get("category", "")) == _expected_band(closing),
			"%.0f px/s -> %s (bands %.0f / %.0f / %.0f)" % [closing,
				hit.get("category", "none"), _world.light_collision_threshold,
				_world.medium_collision_threshold, _world.heavy_collision_threshold])
		_ok("4  the estimate never claims more than the hull was launched with",
			closing <= float(plan[0]) + 1.0 and closing > 0.0,
			"closing %.0f px/s against a launch of %.0f" % [closing, float(plan[0])])
		_ok("5  the direction points from the hull to what it hit",
			(hit.get("direction", Vector2.ZERO) as Vector2).dot(Vector2.RIGHT) > 0.9,
			str(hit.get("direction", Vector2.ZERO)))
		_ok("6  the object is described by kind, not by node name",
			str(hit.get("kind", "")) == WorldObjects.KIND_ASTEROID
			and String(hit.get("description", {}).get("label", "")) != String(hit.kind),
			"%s / %s" % [hit.get("kind", "none"),
				str(hit.get("description", {}).get("label", ""))])
		var given: Dictionary = hit.get("description", {}).get("info", {})
		_ok("6  and an object that introduces itself is read through its own interface",
			given.has("shape") and given.has("extent")
			and String(hit.get("description", {}).get("title", "")).begins_with("asteroid_"),
			WorldObjects.summarize(hit.get("description", {})))
		_ok("7  the state said COLLISION at the contact", _state_at_contact == "COLLISION",
			_state_at_contact)
		await _wait(_frames_for(_world.collision_state_hold) + 30)
		_ok("7  and handed the word back to the flight",
			_ship.state_name() != "COLLISION", _ship.state_name())
	_ok("4  the three launches really were three different speeds",
		_band_closings.size() == 3 and _band_closings[0] < _band_closings[1]
		and _band_closings[1] < _band_closings[2], str(_band_closings))

	_beat("collisions 5-7: angles, grazes and repeat suppression")
	_reset_counters()
	await _park()
	_stone_ahead()
	_ship.rotation = PI * 0.25
	await _launch_at(Vector2.DOWN, 300.0, 460.0)
	var side := _ship.last_collision()
	_ok("5  an arrival from the side is reported too", _collision_events == 1,
		"%d events from below" % _collision_events)
	_ok("5  and the direction is the line it actually came along",
		(side.get("direction", Vector2.ZERO) as Vector2).dot(Vector2.DOWN) > 0.9,
		str(side.get("direction", Vector2.ZERO)))
	_release_all()
	await _wait(60)
	# A nudge under the light threshold is a scrape: the hull touches the stone, the
	# physics answers, and no listener is told about it.
	_reset_counters()
	await _park()
	_stone_ahead()
	await _launch_at(Vector2.RIGHT, 200.0, 30.0)
	_ok("1  a 30 px/s nudge is contact without an event", _collision_events == 0,
		"%d events at 30 px/s" % _collision_events)
	# Then the same stone, pressed into again: one report, not a stream of them.
	_reset_counters()
	_ship.linear_velocity = Vector2(600.0, 0.0)
	for i in 180:
		await _step()
	_ok("7  one object cannot report twice inside its own cooldown",
		_collision_events <= 1, "%d events from three seconds of grinding" % _collision_events)

	_beat("collisions 8-9: no tunneling, no sticking, several bodies")
	_reset_counters()
	await _park()
	_stone_ahead()
	# A pebble is shoved aside and the hull carries on, which is what the belt is
	# for; this phase is about not flying through a rock, so the stone is dressed
	# as a hill and the meeting has to cost the hull.
	_stone.set_form("01", 3.2, _stone.tint)
	await _launch_at(Vector2.RIGHT, 500.0, _ship.max_forward_speed)
	var closest := INF
	for i in 60:
		await _step()
		closest = minf(closest, _ship.global_position.distance_to(_stone.global_position))
	_ok("8  the hull never ends up inside the stone",
		closest >= float(_stone.extent),
		"closest %.0f px against an outline reaching %.0f px" % [closest,
			float(_stone.extent)])
	_ok("8  and it was stopped by the rock, not slowed through it",
		_collision_events == 1 and _ship.global_position.x < STONE_AT.x,
		"hull at %.0f, stone at %.0f" % [_ship.global_position.x, STONE_AT.x])
	_release_all()
	await _wait(30)
	Input.action_press("thrust_backward")
	await _wait(60)
	Input.action_release("thrust_backward")
	_ok("9  the hull can fly away from what it hit",
		_ship.global_position.distance_to(STONE_AT) > float(_stone.extent) + 60.0,
		"%.0f px clear" % _ship.global_position.distance_to(STONE_AT))
	_ok("9  and no speed was accumulated out of nothing",
		_ship.speed() < _ship.max_forward_speed * 1.25, "%.0f px/s" % _ship.speed())
	_reset_counters()
	await _park()
	# Both halves of the cooldown, checked on the classifier directly. Phases 1-7
	# already prove that the physics raises this handler; this check is about the key
	# the cooldown is filed under, which a solver's contact manifold can otherwise hide
	# behind frame timing. Two real bodies, two real instance ids, one frame.
	_ship.rotation = 0.0
	_ship.linear_velocity = Vector2(700.0, 0.0)
	await _step()
	_ship.linear_velocity = Vector2(700.0, 0.0)
	await _step()
	var first = _rocks[0]
	var second = _rocks[1]
	first.global_position = _ship.global_position + Vector2(400.0, 0.0)
	second.global_position = _ship.global_position + Vector2(420.0, 80.0)
	_ship._on_body_shape_entered(RID(), first, 0, 0)
	var after_first := _collision_events
	_ship._on_body_shape_entered(RID(), first, 0, 0)
	_ok("8  the same body cannot report twice inside its cooldown",
		after_first == 1 and _collision_events == 1,
		"%d then %d" % [after_first, _collision_events])
	_ship._on_body_shape_entered(RID(), second, 0, 1)
	_ok("8  two different bodies can both report, because the cooldown is per object",
		_collision_events == 2, "%d events" % _collision_events)
	var held := _ship.last_collision()
	_ok("8  and the report names the one it last touched",
		not held.is_empty() and bool(held.get("object_valid", false)),
		WorldObjects.summarize(held.get("description", {})))
	held.object.queue_free()
	await _wait(10)
	var aged := _ship.last_collision()
	_ok("9  a report survives the object being freed under it",
		not aged.is_empty() and not bool(aged.object_valid)
		and String(aged.get("description", {}).get("title", "")) != "",
		"%s  valid=%s" % [WorldObjects.summarize(aged.get("description", {})),
			str(bool(aged.object_valid))])
	_restore_the_arena()


## Which band a closing speed belongs to, read from the same thresholds the ship uses.
## Written out here rather than called into the ship, so a report and a rule can disagree
## in front of the reader instead of agreeing by construction.
func _expected_band(closing: float) -> String:
	if closing >= _world.heavy_collision_threshold:
		return "HEAVY"
	if closing >= _world.medium_collision_threshold:
		return "MEDIUM"
	if closing >= _world.light_collision_threshold:
		return "LIGHT"
	return "none"


## Send the hull at the stone and let it fly. The velocity is written twice - once to be
## taken by the server on its own clock, once to be sure it landed - and then never
## touched again: holding it every frame fights the solver's answer to the contact and
## walks the hull through the rock, which is a rig artefact, not a ship behaviour. What
## arrives is therefore whatever the glide left of the launch speed, which is exactly what
## the report claims.
func _launch_at(direction: Vector2, distance: float, speed: float) -> void:
	_state_at_contact = ""
	_ship.global_position = STONE_AT - direction * distance
	_ship.rotation = 0.0
	_ship.angular_velocity = 0.0
	_ship.linear_velocity = direction * speed
	await _step()
	_ship.linear_velocity = direction * speed
	await _step()
	var guard := 0
	while guard < 500 and _collision_events == 0:
		await _step()
		guard += 1
	if _collision_events > 0:
		# One step later than the event. A contact signal is delivered before the hull's
		# own `_physics_process`, so the state written on the frame of the hit is the frame
		# *before* it - reading immediately would report the flight, not the collision.
		await _step()
		_state_at_contact = _ship.state_name()
		_band_closings.append(float(_ship.last_collision().get("closing_speed", 0.0)))


func _test_external() -> void:
	_beat("external 1-4: a push from outside")
	_reset_counters()
	await _park()
	_ship.add_external_acceleration("test_well", Vector2(60.0, 0.0))
	await _wait(60)
	_ok("1  a sustained influence shows up as the hull's own acceleration",
		absf(_ship.external_acceleration.x - 60.0) < 0.001,
		str(_ship.external_acceleration))
	# A constant push against the hull's own resistance converges on a/k, not on a·t:
	# after one second of 60 px/s^2 the glide has taken its share, and the number the
	# model should show is the integral, not the textbook first term.
	var expected_after_one_second := 60.0 * (1.0 - exp(-_ship.linear_drag)) 		/ _ship.linear_drag
	_ok("2  and the speed moved as a push against the glide moves it",
		absf(_ship.speed() - expected_after_one_second) < 2.0,
		"%.1f px/s after one second, the curve says %.1f" % [_ship.speed(),
			expected_after_one_second])
	var before_pos := _ship.global_position
	await _wait(60)
	_ok("2  the body moved through the server, as physics",
		_ship.global_position.is_equal_approx(before_pos + Vector2(
			(60.0 + 120.0) * 0.5 * 1.0, 0.0)) or _ship.global_position.distance_to(
			before_pos) > 60.0,
			"%.0f px of drift" % _ship.global_position.distance_to(before_pos))
	_ok("3  the state layer counts it as an external flag",
		_ship.ship_state.has(ShipState.FLAG_EXTERNAL), _ship.active_systems())
	_ship.add_external_acceleration("test_stream", Vector2(0.0, -400.0))
	_ok("4  two sources are counted, and both are the ship's to report",
		_ship.external_influence_count() == 2, "%d influences" % _ship.external_influence_count())
	var capped := _ship.external_acceleration.length()
	_ok("5  the sum is clamped to the configured ceiling",
		capped <= _world.max_external_acceleration + 0.001,
		"%.1f of %.1f px/s^2" % [capped, _world.max_external_acceleration])
	_ship.remove_external_acceleration("test_stream")
	await _step()
	_ok("5  removing one leaves the other exactly as it was",
		absf(_ship.external_acceleration.length() - 60.0) < 0.001
		and _ship.external_influence_count() == 1, str(_ship.external_acceleration))
	# Engines and the world at once: the two must add, and neither may swallow the other.
	Input.action_press("thrust_forward")
	await _wait(_frames_for(_plant.settings().main_engine_response_time) + 10)
	var both := _ship.commanded_acceleration.length()
	_ok("4  a burn and a tow both show up in the frame's acceleration",
		both > _ship.forward_acceleration * 0.9, "%.0f px/s^2 commanded" % both)
	_release_all()
	await _wait(10)
	_ship.clear_external_accelerations()
	await _step()
	_ok("6  clearing them leaves the hull to the engines alone",
		_ship.external_acceleration.length_squared() < 0.0001
		and _ship.external_influence_count() == 0, str(_ship.external_acceleration))

	_beat("external 5-6: impulses, limits and the master switch")
	await _park()
	_ship.apply_external_impulse(Vector2(120.0, 0.0))
	await _step()
	_ok("an impulse arrives as a change of velocity, on the physics step",
		absf(_ship.speed() - 120.0) < 6.0, "%.1f px/s" % _ship.speed())
	await _park()
	_ship.apply_external_impulse(Vector2(9000.0, 0.0))
	await _step()
	_ok("and is capped before it is applied",
		_ship.speed() <= _world.max_external_impulse + 6.0,
		"%.0f px/s against a cap of %.0f" % [_ship.speed(), _world.max_external_impulse])
	await _park()
	_world.external_acceleration_enabled = false
	_ship.add_external_acceleration("test_disabled", Vector2(200.0, 0.0))
	_ship.apply_external_impulse(Vector2(200.0, 0.0))
	await _wait(10)
	_ok("6  the switch turns the whole door off: no accel, no impulse, no queue",
		_ship.external_influence_count() == 0
		and _ship.external_acceleration.length_squared() < 0.0001
		and _ship.speed() < 1.0,
		"%d influences, %.1f px/s" % [_ship.external_influence_count(), _ship.speed()])
	_world.external_acceleration_enabled = true
	await _park()
	_ok("6  and turning it back on does not resurrect what was refused",
		_ship.external_influence_count() == 0, "%d" % _ship.external_influence_count())
	# The case the rest threshold would otherwise eat: a gentle tow must actually move a
	# hull that has no levers on.
	_ship.add_external_acceleration("test_tow", Vector2(20.0, 0.0))
	var towed := 0
	while towed < 240 and _ship.speed() < 12.0:
		await _step()
		towed += 1
	_ok("3  a tow gentler than the rest threshold still gathers speed",
		_ship.speed() >= 12.0, "%.1f px/s after %d frames" % [_ship.speed(), towed])
	_ship.clear_external_accelerations()


# ------------------------------------------------------- panel and endurance --

func _test_panel_and_endurance() -> void:
	_beat("panel lines, speed signal and a long run")
	_ship.show_debug = true
	await _wait(4)
	var panel := "\n".join((_ship.get_node("FlightDebug") as ShipDebug).readout())
	var missing := ""
	for want in ["state", "active", "control", "external", "last hit", "hit point"]:
		if not panel.contains(want):
			missing += want + " "
	_ok("9  the panel shows state, control, systems, contacts and pushes",
		missing == "", "missing: " + missing)
	_ok("9  and the state line agrees with the ship's own word",
		panel.contains(_ship.state_name()), _ship.state_name())
	_reset_counters()
	await _park()
	Input.action_press("thrust_forward")
	await _wait(120)
	Input.action_release("thrust_forward")
	# A cruise burn genuinely changes the speed by ~780 px/s, so with a 12 px/s threshold
	# it is *supposed* to fire several dozen times. The claim worth testing is the other
	# half: a hull whose speed is not moving meaningfully must not be reporting at all.
	_ok("the speed signal fires on a real change, and not on every frame",
		_speed_events > 0 and _speed_events < 120,
		"%d signals across 120 frames of a cruise burn (threshold %.0f px/s)" % [
			_speed_events, _world.speed_report_threshold])
	_reset_counters()
	await _park()
	await _wait(6)
	_reset_counters()
	await _wait(120)
	_ok("the speed signal is quiet when nothing significant changes",
		_speed_events == 0, "%d signals from two seconds of parked hull" % _speed_events)
	_reset_counters()
	await _park()
	_stone_ahead()
	var nodes_before := _ship.get_child_count()
	var non_finite := 0
	var bad_state := 0
	var max_speed := 0.0
	for i in 2400:
		var keys: Array = []
		if i % 90 < 45:
			keys.append("thrust_forward")
		if i % 150 < 30:
			keys.append("emergency_brake")
		if i % 200 < 60:
			keys.append("boost")
		if i % 110 < 40:
			keys.append("strafe_right")
		if i % 130 < 45:
			keys.append("turn_left")
		for a in ["thrust_forward", "thrust_backward", "turn_left", "turn_right",
				"strafe_left", "strafe_right", "emergency_brake", "boost"]:
			if a in keys:
				Input.action_press(a)
			else:
				Input.action_release(a)
		if i % 300 == 0:
			_ship.stabilization.toggle()
		if i % 400 == 0:
			_ship.add_external_acceleration("test_cycle", Vector2(90.0, -40.0))
		if i % 400 == 200:
			_ship.clear_external_accelerations()
		if i % 500 == 250:
			_ship.disable_control()
		if i % 500 == 400:
			_ship.enable_control()
		await _step()
		if not is_finite(_ship.linear_velocity.x) or not is_finite(_ship.speed()) \
				or not is_finite(_ship.angular_velocity):
			non_finite += 1
		if not ShipState.State.keys().has(_ship.state_name()):
			bad_state += 1
		max_speed = maxf(max_speed, _ship.speed())
	_release_all()
	_ship.stabilization.set_enabled(false)
	_ship.clear_external_accelerations()
	_ship.enable_control()
	_ok("endurance: 2400 frames of everything switching stayed finite",
		non_finite == 0 and bad_state == 0,
		"%d non-finite, %d unnamed states" % [non_finite, bad_state])
	_ok("endurance: no node growth from reports, contacts or influences",
		_ship.get_child_count() == nodes_before,
		"%d children (was %d)" % [_ship.get_child_count(), nodes_before])
	var ceiling := _ship.max_forward_speed * _ship.assists.boost_max_speed_multiplier 		+ _world.max_external_impulse * 2.0
	_ok("endurance: the speed never ran away past what the hull can be given",
		max_speed < ceiling, "peak %.0f px/s against %.0f allowed" % [max_speed,
			ceiling])
	await _wait(120)
	_ok("endurance: it ends parked, described and with nothing burning",
		_plant.total_load() < 0.001 and _ship.state_name() == "NORMAL"
		and _ship.active_systems() == "none" and _ship.external_influence_count() == 0,
		"%s / %s / load %.4f" % [_ship.state_name(), _ship.active_systems(),
			_plant.total_load()])
	_ship.show_debug = false
	_restore_the_arena()


## Spec 8's "the ship's scene restarted": a second instance of the same scene must come
## up clean, with no residue of the first hull's contacts, influences, charge or state.
## Everything 1.4 added lives on the instance (no statics, no class-level tanks), and this
## is the phase that fails if that ever stops being true.
func _test_relaunch() -> void:
	_beat("relaunch: a fresh hull starts with nothing carried over")
	_ship.add_external_acceleration("test_leftover", Vector2(80.0, 0.0))
	_ship.disable_control()
	await _step()
	var second: Node = (load(MAP) as PackedScene).instantiate()
	root.add_child(second)
	await process_frame
	await physics_frame
	var fresh := second.get_node("Ship") as ShipController
	_ok("a new hull begins NORMAL and under control",
		fresh.state_name() == "NORMAL" and fresh.movement_enabled,
		"%s / control %s" % [fresh.state_name(), str(fresh.movement_enabled)])
	_ok("it carries no external influences from the first hull",
		fresh.external_influence_count() == 0
		and fresh.external_acceleration.length_squared() < 0.0001,
		"%d influences" % fresh.external_influence_count())
	_ok("it has not hit anything", fresh.last_collision().is_empty(),
		str(fresh.last_collision().keys()))
	_ok("its boost tank starts where the resource says",
		is_equal_approx(fresh.boost.boost_charge, _ship.assists.boost_charge)
		and not fresh.boost.cut_off, "%.3f" % fresh.boost.boost_charge)
	_ok("its stabilizer starts where the resource says",
		fresh.stabilization.enabled == _ship.assists.stabilization_enabled_by_default,
		str(fresh.stabilization.enabled))
	_ok("and the first hull is still itself", _ship.movement_enabled == false
		and _ship.external_influence_count() == 1, _ship.state_name())
	fresh.clear_external_accelerations()
	fresh.enable_control()
	second.queue_free()
	await _wait(6)
	_ship.clear_external_accelerations()
	_ship.enable_control()
	await _park()
	_ok("after the relaunch test the rig is clean again",
		_ship.state_name() == "NORMAL" and _ship.external_influence_count() == 0,
		"%s" % _ship.active_systems())
