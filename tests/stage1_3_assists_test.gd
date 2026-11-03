extends SceneTree

## Sub-stage 1.3 verification: stabilization, emergency braking and boost.
## Run: godot --headless --path . --script tests/stage1_3_assists_test.gd
##
## Stabilization 1-10, emergency brake 1-9, boost 1-10, combined 1-7 - the spec's
## own numbers, as phase names.
##
## The claim under all of it is the one the spec states twice: three more systems
## must not become three more physics. So almost every assertion here is about
## *ownership* or about *superposition*, not about magnitudes:
## - whoever owns a lever owns it alone, and `owners()` says who that was,
## - the assisted hull must be the unassisted hull plus one burn on the axis the
##   assist was given, never plus two,
## - and no assist may write a velocity: the numbers are read off the body after the
##   physics server has had the frame, which is the only place they can come from if
##   there is exactly one writer.
##
## Thresholds are read off `ShipAssistParameters` and the ship's own exports, so a
## retune moves the assertions with it. What this suite cannot see is whether a lit
## nozzle is the nozzle that is actually burning - that is
## tests/stage1_flight_screens.gd, in pixels.

const MAP := "res://scenes/test/TestControlMap.tscn"
const PHASE_STEPS := 9000
## The clear corridor the burns are flown in.
const CORRIDOR := Vector2(0, 1000)

## The stabilization names, exactly as the spec lists them.
const STAB_PARAMS := [
	"stabilization_enabled_by_default", "stabilization_linear_power",
	"stabilization_angular_power", "stabilization_response_time",
	"stabilization_dead_zone", "stabilization_max_lateral_correction",
	"stabilization_max_linear_correction", "stabilization_max_angular_correction",
]
## The emergency brake's, from spec 4 and 9.
const BRAKE_PARAMS := [
	"emergency_brake_max_deceleration", "emergency_brake_stop_threshold",
	"emergency_brake_response_time",
]
## The boost's, exactly as spec 5.4 lists them.
const BOOST_PARAMS := [
	"boost_charge", "boost_drain_rate", "boost_recharge_rate",
	"boost_recharge_delay", "boost_multiplier", "boost_max_speed_multiplier",
	"boost_min_activation_charge", "boost_enabled",
]
const KEYS := ["thrust_forward", "thrust_backward", "turn_left", "turn_right",
		"strafe_left", "strafe_right", "toggle_stabilization", "emergency_brake",
		"boost"]

var _ship: ShipController
var _plant: EngineController
var _fx: EngineVisuals
var _assists: ShipAssistParameters
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
	_assists = _ship.assists
	_rocks = get_nodes_in_group("obstacle")
	for rock in _rocks:
		_homes[rock] = [rock.global_position, rock.global_rotation]
	await process_frame
	await physics_frame

	_beat("architecture")
	_test_architecture()
	_test_parameters()
	await _test_stabilization()
	await _test_emergency_brake()
	await _test_boost()
	await _test_combined()
	await _test_switches_and_panel()
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
	for a in KEYS:
		Input.action_release(a)


## One edge of the toggle key: hold it long enough for the hull's own latch to see
## the transition, then let go. `is_action_just_pressed` cannot be used from a test,
## because a synthetic press is a state and not an event - which is the same reason
## the controller latches the edge itself instead of listening for one.
func _tap_toggle() -> void:
	Input.action_press("toggle_stabilization")
	await _step()
	await _step()
	Input.action_release("toggle_stabilization")
	await _step()


func _park(heading := 0.0) -> void:
	_release_all()
	_clear_the_arena()
	_ship.movement_enabled = true
	_place(CORRIDOR, heading)
	await process_frame
	# A parked hull is a cold hull: every ramp has to start from zero, or the first
	# frames of a phase inherit the burn of the one before it and the ramp being
	# measured is not the ramp being asserted.
	var guard := 0
	while guard < 900 and (_plant.total_load() > 0.001
			or _ship.commanded_acceleration.length() > 0.0001):
		await _step()
		guard += 1
	# A transform written on a RigidBody2D is taken by the server on its own clock,
	# so the placement is re-asserted until it survives a step.
	var settle := 0
	while settle < 30:
		_place(CORRIDOR, heading)
		await _step()
		settle += 1
		if _parked(CORRIDOR, heading):
			break
	if not _parked(CORRIDOR, heading):
		print("   [park] NOT SETTLED: pos=%s rot=%.3f v=%s" % [str(_ship.global_position),
			_ship.rotation, str(_ship.linear_velocity)])


## Park with the stabilizer off *and* its borrowed authority faded out, so a phase
## that switches it on starts where a pilot who just flipped the switch starts.
func _park_cold(heading := 0.0) -> void:
	_release_all()
	_ship.stabilization.set_enabled(false)
	await _park(heading)
	await _wait(_frames_for(_assists.stabilization_response_time) + 20)


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


func _clear_the_arena() -> void:
	for rock in _rocks:
		rock.global_position = Vector2(0, 38000.0)


func _restore_the_arena() -> void:
	for rock in _rocks:
		var home: Array = _homes[rock]
		rock.global_position = home[0]
		rock.global_rotation = home[1]


## Throw the hull at a known velocity and hold it there long enough for the body to
## take the write. Velocity is set on the body, not asked of an engine, because that
## is the only way the model sees a speed it did not make - a bounce, a scrape, a
## planet's wake - which is what an assist has to be able to handle.
func _fling(velocity: Vector2, heading: float = 0.0) -> void:
	_release_all()
	_place(CORRIDOR, heading)
	_ship.linear_velocity = velocity
	_ship.angular_velocity = 0.0
	await _step()
	_ship.linear_velocity = velocity
	await _step()


## Bring the hull down to nothing with whichever lever opposes its motion, then let
## the glide and the rest snap finish. Emergency brake first: it is the fastest thing
## the ship has, and using it here is also a check that it still works at the end of
## a long phase.
func _stop_the_hull() -> void:
	var guard := 0
	while guard < 900 and _ship.speed() > 0.0:
		Input.action_press("emergency_brake")
		await _step()
		guard += 1
	Input.action_release("emergency_brake")
	await _wait(20)


func _frames_for(seconds: float) -> int:
	return maxi(int(ceil(seconds * 60.0)) + 1, 1)


## Refill the tank, clear the empty-lock and send the factor back to 1.0. Boost owns
## a limited resource, so a phase that measures it has to start from a known level -
## not from wherever the previous phase's burn left it, which is how "the rate is
## wrong" gets reported when the real problem is that the tank was already half gone.
func _full_tank() -> void:
	_release_all()
	_ship.boost.boost_charge = 1.0
	_ship.boost.cut_off = false
	_ship.boost.since_use = 0.0
	_ship.boost.factor = 1.0


func _hands() -> String:
	return _ship.owners()


## The px/s^2 the model commanded last frame - the only honest place to read an
## assist's force from, since it is the difference between two velocities the physics
## server owns.
func _commanded() -> Vector2:
	return _ship.commanded_acceleration


## Which of the four `owners()` slots a reader wants, by name. Written out because
## `split("|")[1]` in an assertion says nothing about what it is looking at.
func _owner_of(lever: String) -> String:
	var parts := _hands().split("|")
	match lever:
		"main":
			return parts[0]
		"retro":
			return parts[1]
		"strafe":
			return parts[2]
		"rudder":
			return parts[3]
	return "?"


func _descending(values: Array[float]) -> bool:
	for i in range(1, values.size()):
		if values[i] > values[i - 1] + 0.001:
			return false
	return true


# --------------------------------------------------------------- 0. structure --

## Three systems, one writer, no new physics.
func _test_architecture() -> void:
	_ok("the hull carries all three systems",
		_ship.stabilization != null and _ship.emergency_brake != null
		and _ship.boost != null)
	_ok("the stabilizer starts as the resource says, which is off",
		_ship.stabilization.enabled == _assists.stabilization_enabled_by_default
		and not _assists.stabilization_enabled_by_default,
		"default %s" % str(_assists.stabilization_enabled_by_default))
	# A node would get its own `_physics_process`, and two callers integrating one
	# RigidBody2D is the exact failure the spec forbids. Being plain objects is not a
	# style choice: it is the reason nothing else can write the hull.
	for pair in [["stabilization", _ship.stabilization],
			["emergency_brake", _ship.emergency_brake], ["boost", _ship.boost]]:
		var system = pair[1]
		_ok("%s is not a node" % pair[0], not (system is Node), system.get_class())
		_ok("%s cannot integrate the hull itself" % pair[0],
			not system.has_method("_physics_process")
			and not system.has_method("_process")
			and not system.has_method("apply_force")
			and not system.has_method("apply_impulse"),
			"%s" % system.get_class())
	_ok("the plant still has no way to apply a force",
		not _plant.has_method("apply_force") and not _plant.has_method("apply_impulse"))
	_ok("the three systems read one shared parameter resource",
		_ship.stabilization.parameters == _assists
		and _ship.emergency_brake.parameters == _assists
		and _ship.boost.parameters == _assists)
	_ok("the engine plant still reads the ship's own numbers",
		_plant.settings() == _ship.settings())
	for pair in [["toggle_stabilization", KEY_Z], ["emergency_brake", KEY_SPACE],
			["boost", KEY_SHIFT]]:
		_ok("%s is in the input map" % pair[0], InputMap.has_action(pair[0]))
		_ok("%s answers the key the spec proposes" % pair[0],
			_key_codes(pair[0]).has(pair[1]), str(_key_codes(pair[0])))
	_ok("every lever is reachable as an action, not as a keycode in code",
		InputMap.has_action("thrust_forward") and InputMap.has_action("strafe_right")
		and InputMap.has_action("turn_left"))


func _key_codes(action: String) -> Array:
	var out: Array = []
	if not InputMap.has_action(action):
		return out
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			out.append((ev as InputEventKey).physical_keycode)
	return out


## The parameter contract: every name the spec spells out exists and is exported,
## and the numbers that would break the game in the friendly direction are the wrong
## way round.
func _test_parameters() -> void:
	var names := _editable_names(_assists)
	for n in STAB_PARAMS + BRAKE_PARAMS + BOOST_PARAMS:
		_ok("assists.%s is an inspector parameter" % n, names.has(n))
	_ok("the assist resource carries the whole tuning surface",
		names.size() >= STAB_PARAMS.size() + BRAKE_PARAMS.size() + BOOST_PARAMS.size(),
		"%d exported parameters" % names.size())
	_ok("the stabilizer borrows less than the pilot's brake",
		_assists.stabilization_max_linear_correction < _ship.braking_acceleration,
		"%.0f vs %.0f px/s^2" % [_assists.stabilization_max_linear_correction,
			_ship.braking_acceleration])
	_ok("the stabilizer borrows less than the pilot's strafe",
		_assists.stabilization_max_lateral_correction
		< _ship.settings().maneuvering_engine_power,
		"%.0f vs %.0f px/s^2" % [_assists.stabilization_max_lateral_correction,
			_ship.settings().maneuvering_engine_power])
	_ok("the emergency brake bites harder than S",
		_assists.emergency_brake_max_deceleration > _ship.braking_acceleration,
		"%.0f vs %.0f px/s^2" % [_assists.emergency_brake_max_deceleration,
			_ship.braking_acceleration])
	_ok("the emergency threshold waits for the rest snap",
		_assists.emergency_brake_stop_threshold > _ship.velocity_stop_threshold,
		"%.1f vs %.1f px/s" % [_assists.emergency_brake_stop_threshold,
			_ship.velocity_stop_threshold])
	_ok("the stabilizer's dead zone sits above the rest threshold",
		_assists.stabilization_dead_zone > _ship.velocity_stop_threshold,
		"%.1f vs %.1f px/s" % [_assists.stabilization_dead_zone,
			_ship.velocity_stop_threshold])
	_ok("the stabilizer's turn ceiling leaves room past the passive damping",
		_assists.stabilization_max_angular_correction > _ship.angular_deceleration,
		"%.2f vs %.2f rad/s^2" % [_assists.stabilization_max_angular_correction,
			_ship.angular_deceleration])
	_ok("boost multiplies the engine up, never down",
		_assists.boost_multiplier >= 1.0 and _assists.boost_max_speed_multiplier >= 1.0,
		"x%.2f power, x%.2f ceiling" % [_assists.boost_multiplier,
			_assists.boost_max_speed_multiplier])
	_ok("boost starts, runs and refills inside one tank",
		_assists.boost_min_activation_charge > 0.0
		and _assists.boost_min_activation_charge < _assists.boost_charge
		and _assists.boost_drain_rate > 0.0 and _assists.boost_recharge_rate > 0.0
		and _assists.boost_recharge_delay > 0.0,
		"min %0.2f of %0.2f" % [_assists.boost_min_activation_charge,
			_assists.boost_charge])
	# The two switches the spec asks for, and the two caps it asks for, each checked
	# where a default cannot hide a broken branch.
	var seeded := StabilizationSystem.new(_assists)
	_assists.stabilization_enabled_by_default = true
	var on_by_default := StabilizationSystem.new(_assists)
	_assists.stabilization_enabled_by_default = false
	_ok("stabilization_enabled_by_default seeds a fresh system",
		not seeded.enabled and on_by_default.enabled,
		"%s / %s" % [str(seeded.enabled), str(on_by_default.enabled)])
	_ok("the px/s^2 caps bind the borrow",
		_borrow_at(60.0, 760.0) < 0.09 and _borrow_at(760.0, 760.0) > 0.3,
		"cap 60 of 760 -> %.3f, cap 760 -> %.3f" % [_borrow_at(60.0, 760.0),
			_borrow_at(760.0, 760.0)])


## The assist's own borrow arithmetic, at numbers that are not the shipped defaults:
## the ceiling has to bind below the group's authority and stand aside above it.
func _borrow_at(ceiling: float, group: float) -> float:
	return minf(_assists.stabilization_linear_power, ceiling / group)


func _editable_names(object: Object) -> Array:
	var out: Array = []
	for p in object.get_property_list():
		var name: String = p.name
		var usage: int = p.usage
		var editable := bool(usage & PROPERTY_USAGE_EDITOR) \
			and bool(usage & PROPERTY_USAGE_STORAGE)
		if editable and name != "script" and not name.begins_with("_"):
			out.append(name)
	return out


# -------------------------------------------------------- stabilization 1-10 --

func _test_stabilization() -> void:
	_beat("stabilization 1-2: inertia first, then the toggle")
	await _park_cold()
	Input.action_press("thrust_forward")
	await _wait(90)
	Input.action_release("thrust_forward")
	await _wait(10)
	var free := _ship.speed()
	await _wait(60)
	# One second of nothing but the glide, which is `exp(-linear_drag * t)` - the
	# assist that is switched off must not have taken a single px/s of it.
	var glide_only := free * exp(-_ship.linear_drag * 1.0)
	_ok("1  an unassisted hull keeps flying", _ship.speed() > glide_only * 0.98,
		"%.0f then %.0f px/s, the glide alone says %.0f" % [free, _ship.speed(),
			glide_only])
	await _tap_toggle()
	_ok("2  Z switches the stabilizer on", _ship.stabilization.enabled, _hands())
	await _tap_toggle()
	_ok("2  Z switches it off again", not _ship.stabilization.enabled, _hands())
	await _tap_toggle()
	await _wait(60)
	_ok("2  and the state holds until the next press", _ship.stabilization.enabled,
		"authority %.2f" % _ship.stabilization.authority)

	_beat("stabilization 3: gradual, not a wall")
	await _park_cold()
	await _tap_toggle()
	Input.action_press("thrust_forward")
	await _wait(_frames_for(_plant.settings().main_engine_response_time) + 60)
	Input.action_release("thrust_forward")
	await _wait(30)
	var start := _ship.speed()
	var series: Array[float] = []
	for i in 90:
		await _step()
		series.append(_ship.speed())
	_ok("3  speed falls the whole way", _descending(series) and series[89] < series[0],
		"%.0f -> %.0f px/s" % [series[0], series[89]])
	_ok("3  the hull is still moving at the end of it", series[89] > 0.0,
		"%.1f px/s" % series[89])
	var biggest := 0.0
	for i in range(1, series.size()):
		biggest = maxf(biggest, (series[i - 1] - series[i]) * 60.0)
	var allowance := _assists.stabilization_max_linear_correction \
		+ _ship.linear_drag * start
	_ok("3  no frame takes more than the assist is allowed to",
		biggest <= allowance * 1.15,
		"worst %.0f of %.0f px/s^2 allowed" % [biggest, allowance])
	var settle := 0
	while settle < 600 and _ship.speed() > 0.0:
		await _step()
		settle += 1
	_ok("3  and the correction ends in a park, not a crawl", _ship.speed() == 0.0,
		"%.1f px/s after %d more frames" % [_ship.speed(), settle])

	_beat("stabilization 4: a sideways slide, on its own axis")
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.starboard() * 320.0)
	var across0 := absf(_ship.drift_speed())
	var along0 := _ship.forward_speed()
	await _wait(90)
	_ok("4  the drift goes down", absf(_ship.drift_speed()) < across0 * 0.6,
		"%.0f -> %.0f px/s across" % [across0, _ship.drift_speed()])
	_ok("4  the nose-ward speed is left alone",
		absf(_ship.forward_speed() - along0) < 20.0,
		"along %.1f -> %.1f px/s" % [along0, _ship.forward_speed()])
	_ok("4  and the manoeuvring pair is what burns", absf(_plant.strafe_power) > 0.3,
		"strafe %.2f, brake %.2f" % [_plant.strafe_power, _plant.brake_power])
	var slid := 0
	while slid < 600 and _ship.linear_velocity != Vector2.ZERO:
		await _step()
		slid += 1
	_ok("4  the slide ends stopped", _ship.linear_velocity == Vector2.ZERO,
		"%s after %d frames" % [str(_ship.linear_velocity), slid])

	_beat("stabilization 5: the spec's own picture - nose up, flying east")
	await _park_cold()
	await _tap_toggle()
	await _fling(Vector2(420.0, 0.0), -PI * 0.5)
	var path0 := _ship.linear_velocity.normalized()
	var rot0 := _ship.rotation
	await _wait(90)
	_ok("5  the east speed is the thing that dropped", _ship.speed() < 420.0 * 0.7,
		"%.0f px/s left" % _ship.speed())
	_ok("5  the nose never stopped pointing up",
		absf(wrapf(_ship.rotation - rot0, -PI, PI)) < 0.001,
		"%.4f rad of heading change" % wrapf(_ship.rotation - rot0, -PI, PI))
	var swing := rad_to_deg(acos(clampf(_ship.linear_velocity.normalized().dot(path0),
		-1.0, 1.0)))
	_ok("5  the path never swung around toward the tail", swing < 3.0,
		"%.2f deg off the original line" % swing)
	_ok("5  the sideways axis alone had speed to lose", absf(_ship.forward_speed()) < 20.0,
		"%.1f px/s along the nose" % _ship.forward_speed())

	_beat("stabilization 6-7: the spin stops, the heading stays")
	await _park_cold()
	Input.action_press("turn_left")
	await _wait(60)
	Input.action_release("turn_left")
	var naked := 0
	while naked < 400 and absf(_ship.angular_velocity) > 0.001:
		await _step()
		naked += 1
	var residual := absf(_ship.angular_velocity)
	await _park_cold()
	await _tap_toggle()
	Input.action_press("turn_left")
	await _wait(60)
	Input.action_release("turn_left")
	var heading_at_spin := _ship.rotation
	var quick := 0
	while quick < 400 and absf(_ship.angular_velocity) > 0.001:
		await _step()
		quick += 1
	_ok("6  the assisted spin dies sooner than the passive one", quick < naked,
		"%d frames assisted vs %d passive (leftover %.3f rad/s)" % [quick, naked,
			residual])
	_ok("6  and the rate reaches zero, not a whisper for a minute",
		absf(_ship.angular_velocity) < 0.001, str(_ship.angular_velocity))
	var held := _ship.rotation
	await _wait(120)
	_ok("7  nothing walked the nose back to a heading",
		absf(wrapf(_ship.rotation - held, -PI, PI)) < 0.0001,
		"%.4f rad since the spin ended" % wrapf(_ship.rotation - held, -PI, PI))
	_ok("7  the direction the pilot left it in is kept",
		absf(wrapf(_ship.rotation - heading_at_spin, -PI, PI)) > 0.01,
		"still %.2f rad off where the turn started" % absf(
			wrapf(_ship.rotation - heading_at_spin, -PI, PI)))
	_ok("7  and the verniers are dark now there is no spin",
		_plant.rotation_power < 0.02, "spin power %.3f" % _plant.rotation_power)

	_beat("stabilization 8: the pilot keeps every lever")
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.forward() * 300.0)
	Input.action_press("thrust_forward")
	await _wait(_frames_for(_plant.settings().main_engine_response_time) + 10)
	_ok("8  W owns the along-axis, so the assist is off it",
		_owner_of("retro") != "stabilizer", _hands())
	_ok("8  the engine still delivers exactly its own acceleration",
		_commanded().distance_to(_ship.forward() * _ship.forward_acceleration) < 12.0,
		"%.0f px/s^2 commanded" % _commanded().length())
	Input.action_release("thrust_forward")
	await _wait(6)
	Input.action_press("strafe_right")
	await _wait(_frames_for(_plant.settings().maneuvering_engine_response_time) + 10)
	_ok("8  E owns the sideways axis outright", _owner_of("strafe") == "pilot", _hands())
	_ok("8  and gets the whole group, not the assist's fraction",
		absf(_plant.strafe_power) > _assists.stabilization_linear_power + 0.15,
		"strafe %.2f vs borrow %.2f" % [_plant.strafe_power,
			_assists.stabilization_linear_power])
	Input.action_release("strafe_right")
	await _wait(6)
	Input.action_press("turn_right")
	await _wait(_frames_for(_plant.settings().rotation_engine_response_time) + 10)
	_ok("8  A/D own the yaw axis", _owner_of("rudder") == "pilot", _hands())
	Input.action_release("turn_right")

	_beat("stabilization 9: no tremble at a parked hull")
	await _park_cold()
	await _tap_toggle()
	await _wait(_frames_for(_assists.stabilization_response_time) + 40)
	var churn := 0.0
	var moved := false
	for i in 300:
		await _step()
		churn = maxf(churn, _plant.total_load())
		moved = moved or _ship.global_position.distance_to(CORRIDOR) > 0.01
	_ok("9  three hundred frames with nothing to correct burn nothing", churn < 0.001,
		"worst load %.4f" % churn)
	_ok("9  and the hull does not creep", not moved, str(_ship.global_position))
	_ok("9  velocity is exactly zero, not a small number",
		_ship.linear_velocity == Vector2.ZERO and _ship.angular_velocity == 0.0,
		"%s / %.4f" % [str(_ship.linear_velocity), _ship.angular_velocity])

	_beat("stabilization 10: flipping it over on the move")
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.starboard() * 420.0)
	await _wait(30)
	_ok("10  the assist is holding the slide", absf(_plant.strafe_power) > 0.3,
		"strafe %.2f" % _plant.strafe_power)
	await _tap_toggle()
	var faded := 0
	while faded < 300 and _plant.total_load() > 0.02:
		await _step()
		faded += 1
	_ok("10  switching off takes the borrowed authority back down",
		absf(_plant.strafe_power) < 0.02,
		"strafe %.3f after %d frames" % [_plant.strafe_power, faded])
	var off_at := _ship.speed()
	await _wait(60)
	var pure_glide := off_at * exp(-_ship.linear_drag * 1.0)
	_ok("10  what is left flies on inertia alone",
		absf(_ship.speed() - pure_glide) < pure_glide * 0.04,
		"%.0f px/s kept, the glide alone gives %.0f" % [_ship.speed(), pure_glide])
	await _tap_toggle()
	await _wait(60)
	_ok("10  and switching back on takes the same job up again",
		_ship.speed() < pure_glide * 0.9, "%.0f -> %.0f px/s with the assist on" % [
			pure_glide, _ship.speed()])
	_ok("10  the residual it reports is the drift it is working on",
		_ship.stabilization.residual > 0.0,
		"residual %.1f px/s" % _ship.stabilization.residual)
	await _tap_toggle()


# ---------------------------------------------------------- emergency 1-9 -----

func _test_emergency_brake() -> void:
	_beat("emergency 1: a head-on stop")
	await _park_cold()
	Input.action_press("thrust_forward")
	await _wait(150)
	Input.action_release("thrust_forward")
	await _wait(20)
	var cruise := _ship.speed()
	_ok("1  the hull is at cruise before the key",
		cruise > _ship.max_forward_speed * 0.9, "%.0f px/s" % cruise)
	Input.action_press("emergency_brake")
	await _wait(_frames_for(_assists.emergency_brake_response_time) + 6)
	_ok("1  it delivers its own deceleration, not S's",
		absf(_commanded().length() - _assists.emergency_brake_max_deceleration) < 60.0,
		"%.0f px/s^2 commanded" % _commanded().length())
	_ok("1  and the retro plant is at full authority", _plant.brake_power > 0.9,
		"brake %.2f" % _plant.brake_power)
	_ok("1  the mode says which hand is braking", _ship.mode_name() == "EMERGENCY",
		"%s / %s" % [_ship.mode_name(), _hands()])
	var frames := 0
	while frames < 400 and _ship.speed() > 0.0:
		await _step()
		frames += 1
	var s_frames := cruise / _ship.braking_acceleration * 60.0
	_ok("1  a full stop from cruise", _ship.speed() == 0.0, "%d frames" % frames)
	_ok("1  sooner than the ordinary brake could manage", frames < s_frames,
		"%d frames vs S's %.0f at %.0f px/s^2" % [frames, s_frames,
			_ship.braking_acceleration])
	Input.action_release("emergency_brake")

	_beat("emergency 1b: the bite is faster than S's")
	await _park_cold()
	await _fling(_ship.forward() * 700.0)
	Input.action_press("thrust_backward")
	await _wait(4)
	var s_bite := _plant.brake_power
	_release_all()
	await _wait(_frames_for(_plant.settings().braking_engine_response_time) + 20)
	await _fling(_ship.forward() * 700.0)
	Input.action_press("emergency_brake")
	await _wait(4)
	var eb_bite := _plant.brake_power
	Input.action_release("emergency_brake")
	_ok("the emergency bite is up before the pilot's brake has finished coming up",
		eb_bite > s_bite * 1.4, "4 frames: Space %.2f, S %.2f" % [eb_bite, s_bite])
	# The flame is drawn from the plant's authority, and both levers take that plant to
	# full authority - so what the picture can honestly show is *when* the retro burn
	# comes up, not a brighter flame for Space. Said here in numbers, so the render
	# test only claims what it can see.
	_release_all()
	await _wait(_frames_for(_plant.settings().braking_engine_response_time) + 20)
	await _fling(_ship.forward() * 700.0)
	Input.action_press("thrust_backward")
	await _wait(_frames_for(_plant.settings().braking_engine_response_time) + 4)
	var s_full := _plant.brake_power
	_ok("S reaches the same full authority in the end", s_full > 0.98,
		"brake power %.2f after its own response time" % s_full)
	Input.action_release("thrust_backward")

	_beat("emergency 2-3: sideways, and whatever way the nose points")
	await _park_cold()
	await _fling(_ship.starboard() * 500.0)
	Input.action_press("emergency_brake")
	await _wait(20)
	_ok("2  a beam-on slide brakes along its own line",
		_commanded().dot(_ship.starboard()) < -300.0,
		"%.0f px/s^2 along the drift" % _commanded().dot(_ship.starboard()))
	await _wait(150)
	_ok("2  and the slide is gone", _ship.speed() < 60.0, "%.0f px/s left" % _ship.speed())
	Input.action_release("emergency_brake")
	await _park_cold()
	await _fling(Vector2(600.0, 0.0), -PI * 0.5)
	var path0 := _ship.linear_velocity.normalized()
	var rot0 := _ship.rotation
	var swing := 0.0
	Input.action_press("emergency_brake")
	for i in 60:
		await _step()
		if _ship.speed() > 50.0:
			# The direction is only a statement while there is a direction to have:
			# a normalized near-zero velocity points wherever it likes, and reading a
			# swing out of one would be reading noise.
			swing = maxf(swing, rad_to_deg(acos(clampf(
				_ship.linear_velocity.normalized().dot(path0), -1.0, 1.0))))
	_ok("3  the path never swung toward the tail", swing < 3.0,
		"%.2f deg of swing while it still had speed" % swing)
	_ok("3  the nose stayed exactly where it was put",
		absf(wrapf(_ship.rotation - rot0, -PI, PI)) < 0.001, "%.4f rad" % _ship.rotation)
	_ok("3  and the speed is being spent, not steered", _ship.speed() < 500.0,
		"%.0f px/s" % _ship.speed())
	Input.action_release("emergency_brake")

	_beat("emergency 4: the bottom of the envelope")
	await _park_cold()
	await _fling(_ship.forward() * 4.0)
	Input.action_press("emergency_brake")
	await _wait(20)
	_ok("4  under its threshold the brake does not engage",
		not _ship.emergency_brake.engaged, _ship.emergency_brake.reason)
	_ok("4  nothing burns at a speed it cannot brake", _plant.total_load() < 0.02,
		"load %.3f" % _plant.total_load())
	_ok("4  the rest snap finishes it instead", _ship.speed() == 0.0,
		"%.2f px/s" % _ship.speed())

	_beat("emergency 5: W + Space")
	await _park_cold()
	Input.action_press("thrust_forward")
	await _wait(120)
	Input.action_press("emergency_brake")
	await _wait(_frames_for(_assists.emergency_brake_response_time) + 2)
	_ok("5  Space takes the main engine off the hull", _owner_of("main") == "-", _hands())
	_ok("5  and the retro lever is the brake's",
		_owner_of("retro") == "emergency", _hands())
	# Read while there is still speed to brake. From cruise the emergency stop is over
	# in under a second, and a sample taken after it finishes shows W doing what W is
	# allowed to do again - which is the right behaviour and the wrong evidence.
	var early := _commanded().dot(_ship.forward())
	_ok("5  the net is a slowdown, not two burns cancelling", early < 0.0,
		"%.0f px/s^2 along the nose, with W held" % early)
	var before := _ship.speed()
	var grew_forward := false
	for i in 60:
		await _step()
		grew_forward = grew_forward or _ship.speed() > before + 1.0
	_ok("5  no frame is thrown forward while being braked", not grew_forward,
		"%.0f -> %.0f px/s" % [before, _ship.speed()])
	Input.action_release("emergency_brake")
	Input.action_release("thrust_forward")

	_beat("emergency 6-7: Space with the other three levers")
	await _park_cold()
	await _fling(_ship.forward() * 500.0)
	Input.action_press("emergency_brake")
	Input.action_press("strafe_right")
	await _wait(_frames_for(_plant.settings().maneuvering_engine_response_time) + 2)
	var along := _commanded().dot(_ship.forward())
	var across := _commanded().dot(_ship.starboard())
	_ok("6  the brake still owns the nose axis", along < -400.0,
		"%.0f px/s^2 along" % along)
	# E's own contribution, expected from the geometry rather than assumed: the strafe
	# group's full authority on the sideways axis, plus whatever the retro burn has to
	# pay there once the velocity it aims at has tilted. If the two systems were
	# counting the same thrust twice, or one had swallowed the other, this would not
	# come out - which is spec 6's "no double counting", checked component by component.
	var v_hat := _ship.linear_velocity.normalized()
	var expected := _ship.settings().maneuvering_engine_power * _plant.strafe_power \
		- _assists.emergency_brake_max_deceleration * _plant.brake_power * v_hat.y
	_ok("6  and E still buys its own sideways acceleration, component for component",
		absf(across - expected) < 25.0 and _plant.strafe_power > 0.9,
		"%.0f px/s^2 measured, %.0f expected (strafe %.2f, tilt %.3f)" % [
			across, expected, _plant.strafe_power, v_hat.y])
	Input.action_release("strafe_right")
	Input.action_release("emergency_brake")
	await _park_cold()
	await _fling(_ship.forward() * 500.0)
	Input.action_press("emergency_brake")
	Input.action_press("turn_right")
	await _wait(20)
	_ok("7  the hull can still be pointed while it is being stopped",
		absf(_ship.angular_velocity) > 0.2, "%.2f rad/s of yaw" % _ship.angular_velocity)
	_ok("7  and the brake keeps its deceleration while it turns",
		_commanded().length() > _assists.emergency_brake_max_deceleration * 0.8,
		"%.0f px/s^2" % _commanded().length())
	Input.action_release("turn_right")
	Input.action_release("emergency_brake")

	_beat("emergency 8: letting go, and the astern question")
	await _park_cold()
	await _fling(_ship.forward() * 600.0)
	Input.action_press("emergency_brake")
	await _wait(30)
	Input.action_release("emergency_brake")
	await _wait(_frames_for(_plant.settings().braking_engine_response_time) + 30)
	_ok("8  the brake leaves and the retro plant goes dark",
		not _ship.emergency_brake.engaged and _plant.brake_power < 0.02,
		"brake %.3f" % _plant.brake_power)
	_ok("8  and the mode is not stuck on the emergency name",
		_ship.mode_name() != "EMERGENCY", _ship.mode_name())
	_ok("8  the speed the burn did not take away is still the hull's",
		_ship.speed() > 0.0 and _ship.speed() < 600.0, "%.0f px/s coasting" % _ship.speed())
	var glided := _ship.speed()
	Input.action_press("emergency_brake")
	await _wait(180)
	Input.action_release("emergency_brake")
	await _wait(40)
	_ok("8  held at a dead stop it does not turn into astern",
		_ship.speed() == 0.0 and _ship.forward_speed() >= 0.0,
		"%.2f px/s after 3 s of a held key, from %.0f" % [_ship.speed(), glided])

	_beat("emergency 9: overshoot")
	await _park_cold()
	await _fling(_ship.forward() * 900.0)
	var flipped := false
	var faster := false
	Input.action_press("emergency_brake")
	for i in 400:
		await _step()
		# A reversal is the hull going backwards along the axis it was braking on -
		# `signf(0.0)` is zero, and counting the moment the ship stops as a flip would
		# make this assertion fail on a brake that works.
		flipped = flipped or _ship.forward_speed() < -0.001
		faster = faster or _ship.speed() > 900.0
	Input.action_release("emergency_brake")
	_ok("9  the burn never carries the hull through zero into a reversal", not flipped,
		"along ends at %.1f px/s" % _ship.forward_speed())
	_ok("9  and never makes it faster on the way", not faster, "peak stayed under 900")
	_ok("9  it ends at rest", _ship.linear_velocity == Vector2.ZERO,
		str(_ship.linear_velocity))


# ----------------------------------------------------------------- boost ------

func _test_boost() -> void:
	_beat("boost 1-2: the engine, only harder")
	await _park_cold()
	Input.action_press("thrust_forward")
	await _wait(_frames_for(_plant.settings().main_engine_response_time) + 30)
	var plain := _commanded().length()
	Input.action_release("thrust_forward")
	await _park_cold()
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(_frames_for(_plant.settings().main_engine_response_time)
		+ _frames_for(_assists.boost_ramp_time) + 30)
	var boosted := _commanded().length()
	_ok("1  Shift lights the boost while W drives", _ship.boost.active, _hands())
	_ok("1  the main plant is over its ordinary authority", _plant.main_power > 1.0,
		"main power %.2f" % _plant.main_power)
	_ok("1  the flame is drawn from that over-authority, not from a separate effect",
		_fx.shown(_fx.anchors("main")[0]) > 1.0,
		"shown %.2f" % _fx.shown(_fx.anchors("main")[0]))
	_ok("1  and the mode still says what the burn is", _ship.mode_name() == "FORWARD",
		_ship.mode_name())
	_ok("1  unboosted, the plant stops at its own ceiling",
		absf(_plant.settings().main_engine_max_power - 1.0) < 0.001 and plain
		> _ship.forward_acceleration * 0.9, "%.0f px/s^2 plain" % plain)
	_ok("2  the acceleration is the multiplier it claims",
		absf(boosted / maxf(plain, 1.0) - _assists.boost_multiplier) < 0.08,
		"%.0f -> %.0f px/s^2 (x%.2f asked, x%.2f delivered)" % [plain, boosted,
			_assists.boost_multiplier, boosted / maxf(plain, 1.0)])
	_ok("2  it is the same engine, not a second one",
		absf(boosted - _ship.forward_acceleration * _plant.main_power) < 20.0,
		"%.0f vs forward_acceleration x power %.2f" % [boosted, _plant.main_power])

	_beat("boost 3: the ceiling moves, the hull does not get shaved")
	await _park_cold()
	_full_tank()
	Input.action_press("thrust_forward")
	await _wait(240)
	var cruise := _ship.speed()
	Input.action_press("boost")
	for i in 150:
		await _step()
	_ok("3  boosted cruise is above the ordinary ceiling",
		_ship.speed() > _ship.max_forward_speed * 1.02,
		"%.0f px/s, ceiling %.0f" % [_ship.speed(), _ship.max_forward_speed])
	var limit := _ship.max_forward_speed * _assists.boost_max_speed_multiplier
	_ok("3  and holds at the boosted one", _ship.speed() <= limit + 2.0,
		"%.0f of %.0f px/s" % [_ship.speed(), limit])
	Input.action_release("boost")
	# The ceiling comes down with the authority, and takes nothing off the hull: the
	# engine stops *adding* above 780, it never shaves a speed the ship already owns,
	# which is 1.1's rule and the one a boost is most likely to break.
	var at_release := _ship.speed()
	await _wait(60)
	var glide_floor := at_release * exp(-_ship.linear_drag * 1.0)
	_ok("3  releasing boost removes nothing the glide was not going to",
		_ship.speed() <= at_release + 0.01 and _ship.speed() >= glide_floor * 0.98,
		"%.0f -> %.0f px/s, the glide alone leaves %.0f" % [at_release,
			_ship.speed(), glide_floor])
	Input.action_release("thrust_forward")

	_beat("boost 4-5: the tank runs down and cuts out")
	await _park_cold()
	_full_tank()
	var charge0 := _ship.boost.boost_charge
	Input.action_press("thrust_forward")
	await _wait(30)
	Input.action_press("boost")
	await _wait(20)
	var drained := charge0 - _ship.boost.boost_charge
	var expected := _assists.boost_drain_rate * (20.0 / 60.0)
	_ok("4  charge falls at the configured rate",
		absf(drained - expected) < expected * 0.2 + 0.005,
		"%.3f spent in 20 frames, rate says %.3f" % [drained, expected])
	_ok("4  and the panel reports the same rate",
		is_equal_approx(_ship.boost.charge_rate(), -_assists.boost_drain_rate),
		"%.2f/s" % _ship.boost.charge_rate())
	var frames := 0
	while frames < 900 and _ship.boost.active:
		await _step()
		frames += 1
	_ok("5  it cuts itself off at empty", not _ship.boost.active,
		"charge %.3f after %d frames" % [_ship.boost.boost_charge, frames])
	_ok("5  empty is exactly zero, not a small negative",
		_ship.boost.boost_charge == 0.0, str(_ship.boost.boost_charge))
	await _wait(_frames_for(_plant.settings().main_engine_shutdown_time) + 30)
	_ok("5  and the engine falls back to its own authority",
		absf(_ship.boost.power_multiplier() - 1.0) < 0.001,
		"factor %.3f" % _ship.boost.factor)
	_ok("5  no velocity jump on the way down", _ship.speed() <= cruise * 1.5,
		"%.0f px/s" % _ship.speed())

	_beat("boost 6-7: delay, then the refill")
	# Drive a fresh empty, so the delay is timed from the cut-off event rather than
	# from whenever the previous phase happened to run the tank down. The tank is
	# filled to exactly the activation level: enough to light once, and no charge to
	# lose on the way.
	_release_all()
	await _park(0.0)
	_ship.boost.cut_off = false
	_ship.boost.boost_charge = _assists.boost_min_activation_charge
	_ship.boost.since_use = 0.0
	Input.action_press("thrust_forward")
	await _wait(6)
	Input.action_press("boost")
	var to_empty := 0
	while to_empty < 200 and _ship.boost.boost_charge > 0.0:
		await _step()
		to_empty += 1
	Input.action_release("boost")
	Input.action_release("thrust_forward")
	_ok("6  the tank is empty and the lock is on",
		_ship.boost.boost_charge == 0.0 and _ship.boost.cut_off,
		"%.3f after %d lit frames" % [_ship.boost.boost_charge, to_empty])
	var to_delay := 0
	while to_delay < 400 and _ship.boost.charge_rate() <= 0.0:
		await _step()
		to_delay += 1
	_ok("6  recovery waits out the delay it promises",
		absf(float(to_delay) - float(_frames_for(_assists.boost_recharge_delay))) <= 3.0,
		"%d frames waited, delay says %d" % [to_delay,
			_frames_for(_assists.boost_recharge_delay)])
	var from := _ship.boost.boost_charge
	var need := int(ceil((1.0 - from) / _assists.boost_recharge_rate * 60.0))
	var gain_frames := 0
	while gain_frames < need + 90 and _ship.boost.boost_charge < 1.0:
		await _step()
		gain_frames += 1
	_ok("7  a full tank from here takes the rate it promises",
		absf(gain_frames - need) < need * 0.1 + 6, "%d frames from %.3f, rate says %d" % [
			gain_frames, from, need])
	_ok("7  and stops there", _ship.boost.boost_charge == 1.0
		and _ship.boost.charge_rate() == 0.0, "%.3f" % _ship.boost.boost_charge)
	_ok("7  the lock is off once the activation level is back",
		not _ship.boost.cut_off, str(_ship.boost.cut_off))

	_beat("boost 8: not enough charge to light")
	_full_tank()
	_ship.boost.boost_charge = _assists.boost_min_activation_charge * 0.5
	_ship.boost.cut_off = false
	_release_all()
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(20)
	_ok("8  below the activation level it stays dark", not _ship.boost.active,
		"charge %.3f, min %.3f, reason %s" % [_ship.boost.boost_charge,
			_assists.boost_min_activation_charge, _ship.boost.reason])
	_ok("8  and spends nothing for the attempt",
		absf(_ship.boost.boost_charge
			- _assists.boost_min_activation_charge * 0.5) < 0.0001,
		"%.4f" % _ship.boost.boost_charge)
	_ok("8  the engine is not over-authorised either", _plant.main_power <= 1.001,
		"main %.3f" % _plant.main_power)
	_release_all()

	_beat("boost 9: pumping the lever")
	await _park_cold()
	_full_tank()
	Input.action_press("thrust_forward")
	var lit_frames := 0
	var lit_edges := 0
	var was_lit := false
	var broke_rule := false
	for i in 400:
		if i % 4 < 2:
			Input.action_press("boost")
		else:
			Input.action_release("boost")
		await _step()
		var lit := _ship.boost.active
		if lit and not was_lit:
			lit_edges += 1
		if lit and _ship.boost.cut_off \
				and _ship.boost.boost_charge < _assists.boost_min_activation_charge:
			broke_rule = true
		if lit:
			lit_frames += 1
		was_lit = lit
	Input.action_release("boost")
	Input.action_release("thrust_forward")
	_ok("9  pumping cannot spend more charge than the tank holds",
		_ship.boost.boost_charge >= 0.0, "charge %.3f after 400 frames" % [
			_ship.boost.boost_charge])
	_ok("9  it never lights while the empty-lock is on", not broke_rule,
		"%d light-ups over %d lit frames" % [lit_edges, lit_frames])
	var allowance := 1.0 / _assists.boost_drain_rate * 60.0 \
		+ _assists.boost_recharge_rate * 600.0
	_ok("9  and it cannot be pumped into a longer burn than the tank allows",
		lit_frames <= allowance + 60, "%d lit frames, tank allows %.0f" % [
			lit_frames, allowance])

	_beat("boost 10: letting go of Shift")
	await _park_cold()
	_full_tank()
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(_frames_for(_assists.boost_ramp_time) + 20)
	var at_boost := _plant.main_power
	Input.action_release("boost")
	await _wait(_frames_for(_assists.boost_ramp_time) + 30)
	_ok("10  the boost goes when the key goes", not _ship.boost.active, _hands())
	_ok("10  the authority comes down over its own ramp, not in one frame",
		at_boost > 1.2 and absf(_plant.main_power - 1.0) < 0.02,
		"%.2f -> %.2f" % [at_boost, _plant.main_power])
	_ok("10  and the tank stops being spent", _ship.boost.charge_rate() >= 0.0,
		"rate %.2f/s" % _ship.boost.charge_rate())
	await _wait(30)
	_ok("10  the engine still does what W alone asks", _plant.main_power <= 1.001,
		"main %.3f" % _plant.main_power)
	# 5.2: a boost nobody is driving with must not burn charge.
	Input.action_release("thrust_forward")
	_full_tank()
	await _wait(4)
	var idle_charge := _ship.boost.boost_charge
	Input.action_press("boost")
	await _wait(60)
	Input.action_release("boost")
	_ok("boost 4  held with no W, it neither lights nor drains",
		not _ship.boost.active and _ship.boost.boost_charge == idle_charge,
		"charge %.3f -> %.3f" % [idle_charge, _ship.boost.boost_charge])
	Input.action_release("thrust_forward")


# ------------------------------------------------------------- combined -------

## Does this frame contradict the keys that caused it? An assist may hold an axis
## only while no key does, so the ownership string is checkable against the input
## rather than taken on trust - and a combination that produces a lie here is the
## "two systems fighting for the ship" case the spec asks to be impossible. Returns
## "" when the frame is consistent.
func _clash(combo: Array) -> String:
	var owners := _hands().split("|")
	var holds_main := "thrust_forward" in combo
	var holds_strafe := "strafe_left" in combo or "strafe_right" in combo
	var holds_rudder := "turn_left" in combo or "turn_right" in combo
	if holds_strafe and owners[2] != "pilot":
		return "strafe lever reported as %s while a key holds it" % owners[2]
	if holds_rudder and owners[3] != "pilot":
		return "rudder reported as %s while a key holds it" % owners[3]
	if holds_main and owners[1] == "stabilizer":
		return "the assist took the retro axis while W was driving"
	if _ship.emergency_brake.engaged and owners[0] != "-":
		return "the main engine burned under an emergency brake"
	if not _ship.emergency_brake.engaged and owners[1] == "emergency":
		return "the emergency brake holds the retro lever with its key up"
	if _ship.stabilization.enabled and owners[2] == "stabilizer" \
			and absf(_plant.strafe_power) > _assists.stabilization_linear_power + 0.02:
		return "the assist borrowed %.2f of the manoeuvring group, over its %.2f" % [
			absf(_plant.strafe_power), _assists.stabilization_linear_power]
	return ""

func _test_combined() -> void:
	_beat("combined 1: stabilization with boost")
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.starboard() * 260.0)
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(60)
	_ok("1  the boosted engine keeps the whole nose axis",
		_commanded().dot(_ship.forward()) > _ship.forward_acceleration,
		"%.0f px/s^2 along" % _commanded().dot(_ship.forward()))
	_ok("1  the assist still takes the slide beside it",
		absf(_ship.drift_speed()) < 260.0, "%.0f px/s across" % _ship.drift_speed())
	_ok("1  boost does not touch the manoeuvring group",
		absf(_plant.strafe_power) <= _assists.stabilization_linear_power + 0.02,
		"strafe %.2f while main is x%.2f" % [_plant.strafe_power,
			_ship.boost.power_multiplier()])
	_ok("1  nor the yaw verniers", absf(_plant.rotation_power) < 0.001,
		"spin %.3f" % _plant.rotation_power)
	Input.action_release("boost")
	Input.action_release("thrust_forward")
	await _tap_toggle()

	_beat("combined 2: stabilization under an emergency brake")
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.forward() * 700.0)
	Input.action_press("emergency_brake")
	await _wait(_frames_for(_assists.emergency_brake_response_time) + 10)
	_ok("2  the brake owns the retro lever outright",
		_owner_of("retro") == "emergency", _hands())
	_ok("2  so the assist's fraction is not what is burning",
		_plant.brake_power > 0.9, "brake power %.2f" % _plant.brake_power)
	_ok("2  the deceleration is the brake's own number",
		absf(_commanded().length() - _assists.emergency_brake_max_deceleration) < 80.0,
		"%.0f px/s^2" % _commanded().length())
	Input.action_release("emergency_brake")
	await _wait(30)
	await _tap_toggle()

	_beat("combined 3: Space and Shift together")
	await _park_cold()
	_full_tank()
	await _fling(_ship.forward() * 700.0)
	var charge0 := _ship.boost.boost_charge
	Input.action_press("emergency_brake")
	Input.action_press("boost")
	Input.action_press("thrust_forward")
	await _wait(30)
	_ok("3  the brake wins the linear job", _ship.mode_name() == "EMERGENCY", _hands())
	_ok("3  the boost stands down instead of arguing", not _ship.boost.active,
		"reason %s" % _ship.boost.reason)
	_ok("3  and its tank is not spent on the argument",
		_ship.boost.boost_charge == charge0, "%.3f -> %.3f" % [charge0,
			_ship.boost.boost_charge])
	_ok("3  no frame of it is a chase between two burns", _ship.speed() <= 700.0,
		"%.0f px/s" % _ship.speed())
	_release_all()

	_beat("combined 4: every combination of the levers")
	await _park_cold()
	await _tap_toggle()
	var bad := 0
	var bad_detail := ""
	var combos := [[], ["thrust_forward"], ["thrust_backward"], ["emergency_brake"],
		["thrust_forward", "boost"], ["thrust_forward", "emergency_brake"],
		["thrust_backward", "boost"], ["strafe_left"], ["strafe_right", "boost"],
		["turn_left", "boost"], ["emergency_brake", "strafe_right"],
		["emergency_brake", "turn_left"], ["boost"],
		["thrust_forward", "strafe_left", "turn_right", "boost"],
		["thrust_backward", "strafe_right", "turn_left", "emergency_brake"]]
	for combo in combos:
		await _park(0.0)
		for a in combo:
			Input.action_press(a)
		for i in 45:
			await _step()
			if not is_finite(_ship.linear_velocity.x) or not is_finite(_ship.speed()) \
					or not is_finite(_commanded().length()) \
					or not is_finite(_plant.total_load()):
				bad += 1
				bad_detail = str(combo) + " went non-finite"
		if not ShipController.Mode.keys().has(_ship.mode_name()):
			bad += 1
			bad_detail = str(combo) + " mode " + _ship.mode_name()
		if _plant.main_power > _assists.boost_multiplier + 0.001 \
				or absf(_plant.brake_power) > 1.001 or absf(_plant.astern_power) > 1.001 \
				or absf(_plant.strafe_power) > 1.001 \
				or absf(_plant.rotation_power) > 1.001:
			bad += 1
			bad_detail = str(combo) + " authority out of range: " + str(_plant.report())
		# Two hands on one lever is the conflict the spec asks to be impossible, so
		# every combination has to agree with the keys that produced it.
		var clash := _clash(combo)
		if clash != "":
			bad += 1
			bad_detail = clash
	_release_all()
	await _wait(30)
	_ok("4  fifteen lever combinations all stay finite, in range and singly owned",
		bad == 0, "%d problems: %s" % [bad, bad_detail])
	await _tap_toggle()

	_beat("combined 5-6: a rock, at boost")
	await _park_cold()
	_stone_in_front()
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	var hits := 0
	var guard := 0
	while guard < 400 and hits == 0:
		await _step()
		hits = _ship.get_contact_count()
		guard += 1
	Input.action_release("thrust_forward")
	Input.action_release("boost")
	_ok("5  the boosted hull reaches the stone and is stopped by it", hits > 0,
		"contacts %d after %d frames at x%.2f" % [hits, guard,
			_ship.boost.power_multiplier()])
	_ok("5  the bounce is not eaten by any ceiling", _ship.speed() > 0.0,
		"%.0f px/s after contact" % _ship.speed())
	_ok("5  nothing went non-finite through the impact", is_finite(_ship.speed())
		and is_finite(_ship.angular_velocity), str(_ship.linear_velocity))
	_ok("5  the boost lever came out of the impact inside its tank",
		_ship.boost.boost_charge >= 0.0 and _ship.boost.boost_charge <= 1.0,
		"%.3f" % _ship.boost.boost_charge)
	await _wait(30)
	Input.action_press("emergency_brake")
	await _wait(120)
	Input.action_release("emergency_brake")
	await _wait(30)
	_ok("6  the brake still works after a collision", _ship.speed() < 60.0,
		"%.0f px/s after the emergency stop" % _ship.speed())
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.starboard() * 300.0)
	await _wait(90)
	_ok("6  and the assist still finds the drift afterwards",
		absf(_ship.drift_speed()) < 300.0 * 0.6, "%.0f px/s across" % _ship.drift_speed())
	await _tap_toggle()
	await _wait(60)
	_restore_the_arena()

	_beat("combined 7: a long flight with everything switching")
	await _park_cold()
	var nodes_before := _ship.get_child_count()
	var anchors_before := _fx.anchors().size()
	var charge_min := 1.0
	var charge_max := 0.0
	var worst_load := 0.0
	var non_finite := 0
	var parked_once := false
	for i in 1800:
		if i % 240 == 0:
			await _tap_toggle()
		var keys: Array = []
		if i % 60 < 30:
			keys.append("thrust_forward")
		if i % 100 < 20:
			keys.append("emergency_brake")
		if i % 180 < 90:
			keys.append("boost")
		if i % 70 < 25:
			keys.append("strafe_right")
		if i % 90 < 30:
			keys.append("turn_left")
		for a in KEYS:
			if a in keys:
				Input.action_press(a)
			else:
				Input.action_release(a)
		await _step()
		charge_min = minf(charge_min, _ship.boost.boost_charge)
		charge_max = maxf(charge_max, _ship.boost.boost_charge)
		worst_load = maxf(worst_load, _plant.total_load())
		if not is_finite(_ship.linear_velocity.length()) \
				or not is_finite(_ship.angular_velocity) \
				or not is_finite(_commanded().length()):
			non_finite += 1
		if i > 1200 and _ship.linear_velocity == Vector2.ZERO \
				and _plant.total_load() == 0.0:
			parked_once = true
	_release_all()
	_ok("7  eighteen hundred frames of switching grew no nodes",
		_ship.get_child_count() == nodes_before
		and _fx.anchors().size() == anchors_before,
		"%d children, %d anchors" % [_ship.get_child_count(), _fx.anchors().size()])
	_ok("7  the charge stayed inside its tank",
		charge_min >= 0.0 and charge_max <= 1.0, "%.3f .. %.3f" % [
			charge_min, charge_max])
	_ok("7  the plant never exceeded its authority", worst_load < 6.0,
		"worst total load %.2f" % worst_load)
	_ok("7  no number in the hull ever went non-finite", non_finite == 0,
		"%d frames" % non_finite)
	await _stop_the_hull()
	await _wait(120)
	_ok("7  and the ship ends parked with everything out",
		_ship.linear_velocity == Vector2.ZERO and _plant.total_load() < 0.001
		and absf(_ship.angular_velocity) < 0.001,
		"%s, load %.4f, ever parked mid-flight %s" % [str(_ship.linear_velocity),
			_plant.total_load(), str(parked_once)])


## Drop one stone into the corridor ahead of the hull. `_homes` still holds where it
## came from, so `_restore_the_arena()` puts the belt back.
func _stone_in_front() -> void:
	if _rocks.is_empty():
		return
	var rock = _rocks[0]
	rock.global_position = CORRIDOR + Vector2(1000.0, 0.0)
	rock.linear_velocity = Vector2.ZERO
	rock.angular_velocity = 0.0


# ----------------------------------------------------- switches and the panel --

## The two master switches, the cut-controls case with an assist running, and the
## lines the spec asks the debug panel to print. Left to the end because it writes to
## the shared resource, and every phase before it wants the shipped numbers.
func _test_switches_and_panel() -> void:
	_beat("switches: controls cut, boost disabled, panel complete")
	await _park_cold()
	await _tap_toggle()
	await _fling(_ship.starboard() * 300.0)
	await _wait(_frames_for(_assists.stabilization_response_time) + 20)
	var borrowed := absf(_plant.strafe_power)
	_ship.movement_enabled = false
	await _wait(20)
	_ok("cutting the controls takes the borrowed lever back",
		borrowed > 0.3 and _owner_of("strafe") == "-"
		and absf(_plant.strafe_power) < borrowed * 0.5,
		"borrowed %.2f, hands %s" % [borrowed, _hands()])
	var cut_speed := _ship.speed()
	await _wait(60)
	_ok("and the hull keeps flying on the momentum it had",
		_ship.speed() <= cut_speed + 1.0 and _ship.speed() > cut_speed * 0.6,
		"%.0f -> %.0f px/s with no controls" % [cut_speed, _ship.speed()])
	_ship.movement_enabled = true
	await _tap_toggle()

	# 5.4's `boost_enabled`: off has to mean the lever does nothing at all, and the
	# panel has to say so rather than showing a tank that cannot be spent.
	_assists.boost_enabled = false
	_full_tank()
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	await _wait(_frames_for(_plant.settings().main_engine_response_time) + 20)
	_ok("boost_enabled = false takes the lever away entirely",
		not _ship.boost.active and _ship.boost.boost_charge == 1.0
		and _plant.main_power <= 1.001,
		"charge %.3f, main %.2f, reason %s" % [_ship.boost.boost_charge,
			_plant.main_power, _ship.boost.reason])
	_release_all()
	_assists.boost_enabled = true

	var panel := "\n".join((_ship.get_node("FlightDebug") as ShipDebug).readout())
	var missing := ""
	for want in ["hands", "stab ", "stab resid", "stab borrow", "e-brake", "boost",
			"charge", "boost x", "main", "brake", "strafe", "spin", "thrust", "load"]:
		if not panel.contains(want):
			missing += want + " "
	_ok("the panel prints every line the spec asks the three systems to show",
		missing == "", "missing: " + missing)
	_ok("the panel names the stabilizer's residual drift and the brake's power",
		panel.contains("e-brake    OFF") or panel.contains("e-brake    ON"),
		panel.get_slice("\n", 0) + " / " + str(panel.split("\n").size()) + " lines")
