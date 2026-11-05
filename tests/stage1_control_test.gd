extends SceneTree

## Sub-stage 1.1 verification: the flight model, in the spec's own test letters.
## Run: godot --headless --path . --script tests/stage1_control_test.gd
##
## A  accelerate      B  inertia         C  independence  D  braking
## E  astern          F  angular inertia G  yaw reversal  H  simultaneous keys
## I  collisions      J  endurance
## plus the parameter contract (spec 11), the camera (spec 12), the speed limits
## (spec 9), the controls switch and the diagnostics (spec 13).
##
## Everything is driven through the real InputMap actions, so the bindings are
## part of what is tested and not assumed. Thresholds are read back off the ship's
## own exported parameters rather than hardcoded, which means retuning the flight
## model moves the assertions with it instead of quietly rotting them.
##
## What this cannot prove is how the ship feels. Speeds, ramp times and the drag
## constant all pass here as numbers; the pilot still has to sit in the seat. The
## drawn vectors belong to tests/stage1_flight_screens.gd, which is the only run
## with a real renderer behind it.

const MAP := "res://scenes/test/TestControlMap.tscn"
## How deep the hull may sink into an obstacle before it counts as a failure. The
## solver is allowed a couple of pixels of overlap on the step it notices.
const SINK := 8.0
## Wall-clock budget for the whole routine.
const BUDGET_MS := 300000
## The clear corridor every linear test flies in: y = 1000 with the nose on +X
## keeps 500 px of water between the hull and the nearest stone for the 4500 px
## the longest burn reaches.
const CORRIDOR := Vector2(0, 1000)

var _ship: ShipController
var _cam: Camera2D
var _wall: StaticBody2D
var _sky: Node
var _debug: ShipDebug
var _rocks: Array = []
## Where each stone was authored, so the arena can be cleared and put back.
var _homes := {}
var _wall_half := Vector2.ZERO
var _hits := 0
var _checks := 0
var _failed := 0
var _worst := INF
var _phase := "boot"
var _started := 0
## Physics steps the current phase is allowed, so a rate change inside a phase
## cannot be mistaken for a hang.
var _phase_frames := 0
var _frames_at_start := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
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
	_cam = _ship.get_node("Camera") as Camera2D
	_debug = _ship.get_node("FlightDebug") as ShipDebug
	_wall = scene.get_node("Wall") as StaticBody2D
	_sky = scene.get_node_or_null("Background")
	_rocks = get_nodes_in_group("obstacle")
	for rock in _rocks:
		_homes[rock] = [rock.global_position, rock.global_rotation]
	_wall_half = (_wall.get_node("Shape") as CollisionShape2D).shape.size / 2.0
	_ship.obstacle_hit.connect(_on_hit)
	await process_frame
	await physics_frame

	_beat("setup")
	_test_setup(scene)
	await _test_parameters()
	await _test_a_accelerate()
	await _test_b_inertia()
	await _test_c_independence()
	await _test_d_braking()
	await _test_e_astern()
	await _test_f_angular_inertia()
	await _test_g_yaw_reversal()
	await _test_h_simultaneous()
	await _test_speed_caps()
	await _test_controls_switch()
	await _test_i_collisions()
	await _test_camera()
	await _test_diagnostics()
	await _test_frame_rate_independence()
	await _test_j_endurance()

	_ok("nothing was ever sunk into an obstacle", _worst >= SINK,
		"worst clearance=%.1f px" % _worst)
	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS",
		"  contacts=", _hits)
	quit(1 if _failed else 0)


# ------------------------------------------------------------------ plumbing --

func _on_hit(_obstacle: Node, _closing: float) -> void:
	_hits += 1


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _beat(tag: String, frames := 4000) -> void:
	_phase = tag
	_phase_frames = frames
	_frames_at_start = Engine.get_physics_frames()
	print("-- %s   t=%.0fs  physics=%d" % [tag, _elapsed(), Engine.get_physics_frames()])


func _elapsed() -> float:
	return (Time.get_ticks_msec() - _started) / 1000.0


## One physics step, with the field scan and the watchdog that go with it.
func _step() -> void:
	await physics_frame
	_worst = minf(_worst, _clearance())
	# the rate tests run the clock at 30 and 120 Hz, and the watchdog budget is
	# wall-clock, so it has to be read off the simulation rather than the wrist
	if Engine.get_physics_frames() > _frames_at_start + _phase_frames:
		print("WATCHDOG  stuck in phase '", _phase, "' after ", _elapsed(), " s")
		quit(3)


func _wait(frames: int) -> void:
	for i in frames:
		await _step()


func _release_all() -> void:
	for a in ["thrust_forward", "thrust_backward", "turn_left", "turn_right"]:
		Input.action_release(a)


## Put the ship somewhere, pointing at `heading`, dead still. The camera is snapped
## along with it: everything below moves the ship by teleport, and the follow
## filter would otherwise spend the next second catching up instead of testing.
func _park(at := CORRIDOR, heading := 0.0) -> void:
	_release_all()
	_ship.movement_enabled = true
	_ship.rotation = heading
	_ship.angular_velocity = 0.0
	_ship.linear_velocity = Vector2.ZERO
	_ship.global_position = at
	_worst = minf(_worst, _clearance())
	if _cam != null:
		_cam.snap()
	# Cold start, every time. The plant's ramps outlive the key that asked for them, so a
	# phase that begins while the previous burn is still fading inherits a head start it
	# never asked for - and the "watched and unwatched flights must be identical" check
	# compares two halves that had different engines warm, which is a confounder, not a
	# finding.
	var cold := 0
	while cold < 200 and (_ship.engines.total_load() > 0.001
			or _ship.commanded_acceleration.length() > 0.0001):
		await _step()
		cold += 1
	# Physics, not a draw frame: a heavier overlay makes one `process_frame` span two or
	# three ticks, and a rig that waits on the draw clock hands the two halves of a
	# "same flight, watched and unwatched" comparison different numbers of steps - which
	# reads as the overlay moving the ship.
	#
	# And re-asserted until it survives a step, for the reason 1.2 and 1.3 both learned
	# the hard way: a transform written on a RigidBody2D is taken by the server on its own
	# clock, so one step after the write can still hand back the previous phase's pose.
	# The two halves of the overlay comparison were landing on opposite sides of that
	# flush, which is exactly the "the debug layer flies the ship" failure they are meant
	# to rule out - and it was real, deterministic and reproducible.
	var settle := 0
	while settle < 30:
		_ship.rotation = heading
		_ship.angular_velocity = 0.0
		_ship.linear_velocity = Vector2.ZERO
		_ship.global_position = at
		await _step()
		settle += 1
		if (_ship.global_position.distance_to(at) < 0.5
				and absf(wrapf(_ship.rotation - heading, -PI, PI)) < 0.001
				and _ship.linear_velocity.length() < 0.5):
			break


## The same, with the nose aimed at a point - so the collision cases do not carry
## heading constants that only make sense in whatever frame the art happens to
## have been drawn in.
func _park_aimed(at: Vector2, target: Vector2) -> void:
	await _park(at, (target - at).angle())


func _speed() -> float:
	return _ship.linear_velocity.length()


## How the model says the speed should look `t` seconds after the engines went
## quiet: the glide is a pure exponential, so anything below this is a brake that
## nobody asked for.
func _glide_of(v0: float, t: float) -> float:
	return v0 * exp(-_ship.linear_drag * t)


## How far the hull centre sits outside whatever it is nearest to, in px: an
## obstacle's own reach along the line between us, the wall as a rectangle. Inside
## anything, this goes negative.
func _clearance() -> float:
	var closest := INF
	for rock in _rocks:
		var to_ship: Vector2 = rock.global_position.direction_to(_ship.global_position)
		closest = minf(closest, rock.global_position.distance_to(_ship.global_position)
			- rock.reach_toward(to_ship))
	var local := _wall.to_local(_ship.global_position)
	var ox := maxf(absf(local.x) - _wall_half.x, 0.0)
	var oy := maxf(absf(local.y) - _wall_half.y, 0.0)
	if ox == 0.0 and oy == 0.0:
		return minf(closest, -minf(_wall_half.x - absf(local.x), _wall_half.y - absf(local.y)))
	return minf(closest, sqrt(ox * ox + oy * oy))


func _pick_smallest() -> Node2D:
	var best: Node2D = _rocks[0]
	for rock in _rocks:
		if rock.extent < best.extent:
			best = rock
	return best


func _pick_largest() -> Node2D:
	var best: Node2D = _rocks[0]
	for rock in _rocks:
		if rock.extent > best.extent:
			best = rock
	return best


## Lift every stone far out of the flying area, for a run that is about the four
## levers rather than about collisions. The stones are frozen walls, so parking
## them 38000 px away is exactly that: a genuinely empty sky.
func _clear_the_arena() -> void:
	for rock in _rocks:
		rock.global_position = Vector2(0, 38000.0)


## Put them back where the scene authored them, outline and all, so every later
## phase measures the same map the first one did.
func _restore_the_arena() -> void:
	for rock in _rocks:
		var home: Array = _homes[rock]
		rock.global_position = home[0]
		rock.global_rotation = home[1]
		rock.linear_velocity = Vector2.ZERO


## Script variables the inspector can actually edit, which is what `@export` buys.
## Measured on this build: an exported member carries usage 4102 (STORAGE|EDITOR|
## SCRIPT_VARIABLE), a plain `var` carries 4096 - so the editor bit is the one
## that tells the tuning surface apart from the plumbing.
func _tunable() -> Array[String]:
	var out: Array[String] = []
	for p in _ship.get_property_list():
		var name := String(p.name)
		var editable := bool(p.usage & PROPERTY_USAGE_EDITOR) and bool(p.usage & PROPERTY_USAGE_STORAGE)
		if bool(p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) and editable and not name.begins_with("_"):
			out.append(name)
	return out


# ------------------------------------------------- 0. the parts of the stage --

func _test_setup(scene: Node) -> void:
	var backdrop: ColorRect = scene.get_node("Void")
	_ok("ship scene is self-contained", _ship is RigidBody2D and _cam != null
		and _cam.is_current(), "camera current=%s" % str(_cam.is_current()))
	_ok("the ship is a free-falling body, not a character",
		is_zero_approx(_ship.gravity_scale) and not _ship.freeze and not _ship.can_sleep,
		"gravity=%s freeze=%s sleep=%s" % [_ship.gravity_scale, _ship.freeze,
		_ship.can_sleep])
	_ok("nothing but this controller slows the hull: the body's own damping is off",
		_ship.linear_damp_mode == RigidBody2D.DAMP_MODE_REPLACE
		and _ship.angular_damp_mode == RigidBody2D.DAMP_MODE_REPLACE
		and is_zero_approx(_ship.linear_damp) and is_zero_approx(_ship.angular_damp),
		"linear=%.2f angular=%.2f" % [_ship.linear_damp, _ship.angular_damp])
	_ok("the hull reports its contacts and is not tunnel-prone",
		_ship.continuous_cd and _ship.contact_monitor and _ship.max_contacts_reported > 0,
		"cc=%s monitor=%s reports=%d" % [_ship.continuous_cd, _ship.contact_monitor,
		_ship.max_contacts_reported])
	var airframe: Sprite2D = scene.get_node("Ship/Visuals/Sprite2D")
	# The cruiser is cut at game scale, so it is drawn 1:1 - a scale of 2 here would
	# silently double a 282 px hull and leave the collision slabs half its size.
	_ok("the hull is drawn from the real airframe", airframe.texture != null
		and airframe.texture.get_size() == Vector2(284, 97)
		and airframe.scale.is_equal_approx(Vector2.ONE),
		"%s at scale %s" % [str(airframe.texture.get_size()), str(airframe.scale)])
	_ok("the sky streams from the ship's camera", _sky != null and _sky.has_method("stats"),
		str(_sky))
	if _sky != null:
		var st: Dictionary = _sky.stats()
		_ok("the sky is populated at the start", int(st.nodes) > 20, str(st))
	var radii := {}
	var art := 0
	for rock in _rocks:
		radii[rock.name] = rock.extent
		if rock.sprite.texture != null and rock.extent > 0.0:
			art += 1
	_ok("several obstacles of different sizes", _rocks.size() >= 6 and radii.size() >= 5,
		str(radii.values()))
	_ok("every obstacle carries its art and its outline", art == _rocks.size(),
		"%d of %d" % [art, _rocks.size()])
	_ok("the map is a dark void", backdrop.color.v < 0.1, str(backdrop.color))
	for pair in [["thrust_forward", 87], ["thrust_backward", 83],
			["turn_left", 65], ["turn_right", 68]]:
		var bound := false
		for e in InputMap.action_get_events(pair[0]):
			if e is InputEventKey and e.physical_keycode == pair[1]:
				bound = true
		_ok("key bound: " + pair[0], bound, "physical_keycode=%d" % pair[1])


## The parameter contract from spec 11: twelve names, all in the inspector, all
## settable at runtime, all shaped by the relationships the stage promises.
func _test_parameters() -> void:
	_beat("parameters")
	var tunable := _tunable()
	var floats := ["max_forward_speed", "max_reverse_speed", "forward_acceleration",
		"reverse_acceleration", "braking_acceleration", "linear_drag",
		"max_angular_speed", "angular_acceleration", "angular_deceleration",
		"velocity_stop_threshold", "angular_stop_threshold"]
	for name in floats:
		var value: Variant = _ship.get(name)
		_ok("%s is an exported, tunable number" % name,
			tunable.has(name) and value is float and value > 0.0,
			"%s = %s" % [name, str(value)])
	_ok("movement_enabled is an exported switch", tunable.has("movement_enabled")
		and _ship.get("movement_enabled") is bool, str(_ship.movement_enabled))
	_ok("astern is the weaker lever than the engine it backs away from",
		_ship.reverse_acceleration < _ship.forward_acceleration
		and _ship.max_reverse_speed < _ship.max_forward_speed,
		"%.0f of %.0f px/s^2, %.0f of %.0f px/s" % [_ship.reverse_acceleration,
		_ship.forward_acceleration, _ship.max_reverse_speed, _ship.max_forward_speed])
	_ok("braking out-pulls the engine it has to stop",
		_ship.braking_acceleration > _ship.forward_acceleration,
		"%.0f against %.0f px/s^2" % [_ship.braking_acceleration,
		_ship.forward_acceleration])
	_ok("the glide is weak enough to read as inertia",
		_ship.linear_drag > 0.0 and _ship.linear_drag < 0.5,
		"half the speed survives %.1f s" % (log(2.0) / _ship.linear_drag))
	_ok("the stop thresholds sit below anything the pilot can see",
		_ship.velocity_stop_threshold < _ship.max_forward_speed * 0.02
		and _ship.angular_stop_threshold < _ship.max_angular_speed * 0.05,
		"%.1f px/s, %.3f rad/s" % [_ship.velocity_stop_threshold,
		_ship.angular_stop_threshold])

	# and the numbers are the flight, not a document
	var was_cruise: float = _ship.max_forward_speed
	var was_drag: float = _ship.linear_drag
	_ship.linear_drag = 0.0
	_ship.max_forward_speed = 120.0
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(120)
	_ok("retuning reaches the flight, not only the inspector",
		absf(_ship.forward_speed() - 120.0) < 1.0,
		"ceiling 120 asked for, %.1f px/s earned" % _ship.forward_speed())
	Input.action_release("thrust_forward")
	_ok("with the glide switched off the ship really does coast forever",
		_speed() > 119.0, "%.1f px/s after letting go" % _speed())
	await _wait(120)
	_ok("and keeps going", _speed() > 119.0, "%.1f px/s two seconds on" % _speed())
	_ship.max_forward_speed = was_cruise
	_ship.linear_drag = was_drag
	await _park(CORRIDOR, 0.0)


# ---------------------------------------------------- test A. the main engine --

func _test_a_accelerate() -> void:
	_beat("test A accelerate")
	var cruise: float = _ship.max_forward_speed
	await _park(CORRIDOR, 0.0)
	_ok("a parked ship reports the idle mode",
		_ship.movement_mode == ShipController.Mode.IDLE, _ship.mode_name())
	Input.action_press("thrust_forward")
	await _step()
	var first := _speed()
	var power_first := _ship.engines.main_power
	await _wait(20)
	var early := _speed()
	_ok("W builds speed instead of jumping to it",
		first < cruise * 0.05 and early < cruise * 0.35,
		"1 frame=%.1f, 20=%.1f, cap=%.1f px/s" % [first, early, cruise])
	# 1.2 put a ramp in front of the engine: the flight model's acceleration is now
	# what the hull sees once the engine is at full power, and the first frames are
	# deliberately softer than that number.
	_ok("the engine comes up over its response time, not in one frame",
		power_first < 0.5 and _ship.engines.main_power > 0.9,
		"power %.2f on the first frame, %.2f after 21" % [power_first,
		_ship.engines.main_power])
	_ok("at full power the ramp is exactly the exported acceleration",
		absf(_ship.commanded_acceleration.length()
		- _ship.forward_acceleration * _ship.engines.main_power) < 2.0,
		"%.0f px/s^2 of %.0f at power %.2f" % [_ship.commanded_acceleration.length(),
		_ship.forward_acceleration, _ship.engines.main_power])
	_ok("W names the mode FORWARD", _ship.movement_mode == ShipController.Mode.FORWARD,
		_ship.mode_name())

	var frames := 21
	var steady := true
	var before := early
	var biggest := 0.0
	while frames < 420 and _ship.forward_speed() < cruise * 0.985:
		await _step()
		frames += 1
		if _ship.forward_speed() < before - 0.5:
			steady = false
		biggest = maxf(biggest, _speed() - before)
		before = _ship.forward_speed()
	_ok("W climbs to the cruise ceiling", _ship.forward_speed() >= cruise * 0.98,
		"%.1f of %.1f px/s in %.1f s" % [_ship.forward_speed(), cruise, frames / 60.0])
	_ok("the climb is steady all the way up", steady
		and biggest <= _ship.forward_acceleration / 60.0 * 1.2,
		"biggest one-frame gain=%.1f px/s" % biggest)
	_ok("W drives along the ship, not the screen",
		_ship.linear_velocity.normalized().dot(_ship.forward()) > 0.995
		and absf(_ship.drift_speed()) < cruise * 0.02,
		"drift=%.1f px/s sideways" % _ship.drift_speed())
	_ok("the commanded acceleration points at the nose",
		_ship.commanded_acceleration.normalized().dot(_ship.forward()) > 0.999,
		"%.0f px/s^2" % _ship.commanded_acceleration.length())
	# settle onto the ceiling first: the loop above stops the moment 98.5% is
	# crossed, and the last few frames are still climbing into the clamp
	await _wait(30)
	_ok("sitting on the cruise ceiling the engine only holds against the glide",
		absf(_ship.commanded_acceleration.length()
		- _ship.linear_drag * _ship.max_forward_speed) < 8.0,
		"commanded %.0f px/s^2, the void takes %.0f at this speed"
		% [_ship.commanded_acceleration.length(),
		_ship.linear_drag * _ship.max_forward_speed])
	_ok("holding W at the ceiling does not accelerate further",
		_ship.forward_speed() <= cruise * 1.005, "%.1f px/s" % _ship.forward_speed())
	Input.action_release("thrust_forward")


# -------------------------------------------------------- test B. inertia ------

func _test_b_inertia() -> void:
	_beat("test B inertia")
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(240)
	Input.action_release("thrust_forward")
	# the shutdown ramp keeps the engine leaning on the hull for a beat after the
	# key comes off, so the coast is only measured once the plant is cold
	await _wait(40)
	var released := _speed()
	var heading := _ship.linear_velocity.normalized()
	await _wait(30)
	var coasted := _speed()
	_ok("the ship keeps flying with nothing pressed", coasted > released * 0.8,
		"%.0f -> %.0f px/s over 0.5 s" % [released, coasted])
	_ok("coasting keeps its heading",
		_ship.linear_velocity.normalized().dot(heading) > 0.999
		and absf(_ship.angular_velocity) < 0.02,
		"yaw=%.2f rad/s" % _ship.angular_velocity)
	_ok("letting go of W is coasting, not braking",
		_ship.movement_mode == ShipController.Mode.IDLE
		and _ship.commanded_acceleration.length() < 1.0,
		"%s, commanded %.1f px/s^2" % [_ship.mode_name(),
		_ship.commanded_acceleration.length()])
	var start := _ship.global_position
	await _wait(60)
	var gone := _ship.global_position.distance_to(start)
	# what the model itself promises: the integral of an exponentially decaying
	# speed over the second that just went by
	var expect := released * (1.0 - exp(-_ship.linear_drag)) / maxf(_ship.linear_drag, 0.001)
	_ok("inertia covers real ground", gone > 300.0 and gone > expect * 0.7,
		"%.0f px in 1 s of pure glide, the model promises %.0f" % [gone, expect])
	await _wait(300)
	_ok("space resistance bleeds the glide off gradually",
		_speed() < coasted * 0.6 and _speed() > 1.0,
		"%.0f px/s left after 6 s" % _speed())
	var left := _speed()
	var owed := _glide_of(released, 6.5)
	_ok("and the only thing that took it back is the drag",
		absf(left - owed) < owed * 0.02 + 1.0,
		"%.0f px/s measured, %.0f px/s promised by linear_drag=%.2f" % [left, owed,
		_ship.linear_drag])
	_ok("the speed was never zeroed on release",
		released > _ship.max_forward_speed * 0.85,
		"%.0f px/s on the frame W came off" % released)


# ------------------------- test C. the nose and the path are not the same thing

func _test_c_independence() -> void:
	_beat("test C independence of heading and velocity")
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(150)
	Input.action_release("thrust_forward")
	var earned := _ship.linear_velocity
	var path := earned.angle()
	# swing the hull a quarter turn and no further: at 90 degrees the drift is all
	# of the speed and the nose has none of it, which is the number the spec's
	# example is about
	Input.action_press("turn_left")
	var guard := 0
	while guard < 140 and absf(wrapf(_ship.rotation, -PI, PI)) < PI * 0.5:
		await _step()
		guard += 1
	Input.action_release("turn_left")
	var swung := absf(wrapf(_ship.rotation, -PI, PI))
	_ok("the hull really turned a quarter of a turn", swung > 1.4,
		"%.0f deg of yaw in %.2f s" % [rad_to_deg(swung), guard / 60.0])
	_ok("the velocity vector did not follow the nose",
		absf(wrapf(_ship.linear_velocity.angle() - path, -PI, PI)) < 0.03,
		"path moved %.3f rad while the hull turned %.0f deg"
		% [_ship.linear_velocity.angle() - path, rad_to_deg(swung)])
	_ok("all of the earned speed is now sideways",
		absf(_ship.drift_speed()) > _speed() * 0.99
		and absf(_ship.forward_speed()) < _speed() * 0.05,
		"across=%.0f, along=%.0f of %.0f px/s" % [_ship.drift_speed(),
		_ship.forward_speed(), _speed()])
	_ok("the hull is facing where the ship is not going",
		absf(_ship.forward().dot(_ship.linear_velocity.normalized())) < 0.05,
		"nose and path %.1f deg apart" % rad_to_deg(
		absf(_ship.forward().angle_to(_ship.linear_velocity))))
	var before_bend := _ship.linear_velocity.angle()
	Input.action_press("thrust_forward")
	await _wait(30)
	var bent := absf(wrapf(_ship.linear_velocity.angle() - before_bend, -PI, PI))
	Input.action_release("thrust_forward")
	_ok("only thrust bends the path, and only after it is lit", bent > 0.05,
		"%.3f rad bent in 0.5 s of burn" % bent)


# ------------------------------------------------------- test D. braking -------

func _test_d_braking() -> void:
	_beat("test D braking")
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(240)
	Input.action_release("thrust_forward")
	var cruising := _speed()
	Input.action_press("thrust_backward")
	var frames := 0
	var sharpest := 0.0
	var fought := 0
	var flipped := 0
	var was := cruising
	var was_dir := _ship.linear_velocity.normalized()
	while frames < 400 and _speed() > _ship.velocity_stop_threshold:
		await _step()
		frames += 1
		sharpest = maxf(sharpest, was - _speed())
		was = _speed()
		if _ship.commanded_acceleration.dot(_ship.linear_velocity) > 0.0:
			fought += 1
		var now_dir := _ship.linear_velocity.normalized()
		if now_dir.dot(was_dir) < 0.0:
			flipped += 1
		was_dir = now_dir
	_ok("S names the mode BRAKING while the ship still moves",
		_ship.movement_mode == ShipController.Mode.BRAKING
		or _speed() <= _ship.velocity_stop_threshold, _ship.mode_name())
	_ok("S pulls the ship down in a controllable time",
		frames > 18 and frames < 180,
		"%.2f s from %.0f px/s" % [frames / 60.0, cruising])
	_ok("the braking is a burn, not a switch",
		sharpest <= _ship.braking_acceleration / 60.0 * 1.2,
		"sharpest one-frame drop=%.1f px/s of %.0f" % [sharpest,
		_ship.braking_acceleration])
	_ok("the burn points back along the velocity, never across it", fought == 0,
		"%d frames of thrust along the direction of travel" % fought)
	_ok("braking to a stop never reverses the heading on its own", flipped == 0,
		"%d frames with the velocity vector flipped" % flipped)
	Input.action_release("thrust_backward")
	await _wait(30)
	_ok("a braked ship stays stopped instead of creeping", _speed() <= 1.0,
		"%.2f px/s after 0.5 s with nothing pressed" % _speed())
	var parked := _ship.global_position
	await _wait(120)
	_ok("and does not start backing away on its own",
		_ship.global_position.distance_to(parked) < 2.0,
		"%.1f px drifted" % _ship.global_position.distance_to(parked))
	await _test_d_broadside()


## Spec 6's worked example: flying to the right, nose swung up, S pulls to the
## left. The brake has to answer the motion rather than the hull, and a broadside
## ship has no engine pointing at the drift at all.
func _test_d_broadside() -> void:
	_beat("test D broadside")
	await _park(CORRIDOR, -PI * 0.5)
	_ship.linear_velocity = Vector2(600.0, 0.0)
	Input.action_press("thrust_backward")
	await _step()
	var accel := _ship.commanded_acceleration
	_ok("braking answers the motion, not the hull",
		accel.dot(_ship.linear_velocity) < 0.0
		and absf(accel.y) < absf(accel.x) * 0.05,
		"accel=(%.0f, %.0f) against v=(%.0f, %.0f)" % [accel.x, accel.y,
		_ship.linear_velocity.x, _ship.linear_velocity.y])
	await _wait(20)
	_ok("and it bites at the full exported rate once the retro group is up",
		_ship.commanded_acceleration.x < -_ship.braking_acceleration * 0.9,
		"%.0f px/s^2 of %.0f" % [_ship.commanded_acceleration.x,
		_ship.braking_acceleration])
	_ok("and it is named BRAKING while there is speed left",
		_ship.movement_mode == ShipController.Mode.BRAKING, _ship.mode_name())
	var along_leaks := 0
	var frames := 0
	while frames < 200 and _speed() > _ship.velocity_stop_threshold:
		await _step()
		frames += 1
		if absf(_ship.forward_speed()) > 40.0:
			along_leaks += 1
	Input.action_release("thrust_backward")
	_ok("slowing down broadside invents no speed along the nose",
		along_leaks == 0, "%d frames with %.0f px/s along it"
		% [along_leaks, _ship.forward_speed()])
	_ok("the sideways flight was burned off, not steered",
		absf(_ship.linear_velocity.x) < 60.0, "%.0f px/s of rightward speed left"
		% _ship.linear_velocity.x)
	await _wait(30)
	_ok("a sideways ship can be parked with the brakes alone", _speed() < 2.0,
		"%.2f px/s" % _speed())


# ------------------------------------------------------- test E. astern --------

func _test_e_astern() -> void:
	_beat("test E astern")
	# nose pointing down-screen, so the astern burn walks the ship up the clear
	# corridor instead of into the stones parked off the origin
	await _park(CORRIDOR, PI * 0.5)
	var start := _ship.global_position
	Input.action_press("thrust_backward")
	await _step()
	_ok("a stopped ship under S is reversing, not braking",
		_ship.movement_mode == ShipController.Mode.REVERSING, _ship.mode_name())
	_ok("the astern burn is aimed out of the tail",
		_ship.commanded_acceleration.length() > 0.0
		and _ship.commanded_acceleration.dot(_ship.forward()) < 0.0,
		"%.0f px/s^2 pointing away from the nose"
		% _ship.commanded_acceleration.length())
	await _wait(30)
	_ok("and it reaches the exported ramp once the thrusters are at full power",
		absf(_ship.commanded_acceleration.length() - _ship.reverse_acceleration) < 2.0,
		"%.0f px/s^2 of %.0f" % [_ship.commanded_acceleration.length(),
		_ship.reverse_acceleration])
	await _wait(240)
	_ok("S drives astern",
		_ship.forward_speed() <= -_ship.max_reverse_speed * 0.9,
		"along=%.1f of cap=%.1f px/s" % [_ship.forward_speed(), _ship.max_reverse_speed])
	_ok("S walked the ship backwards along its own nose",
		(_ship.global_position - start).dot(_ship.forward()) < -150.0,
		"%.0f px" % (_ship.global_position - start).dot(_ship.forward()))
	await _wait(240)
	_ok("holding S cannot run past the astern ceiling",
		_ship.forward_speed() >= -_ship.max_reverse_speed * 1.05,
		"%.1f px/s after 8 s" % _ship.forward_speed())
	_ok("astern is the gentler lever than the engine",
		absf(_ship.forward_speed()) < _ship.max_forward_speed * 0.5,
		"%.0f of %.0f px/s cruise" % [_ship.forward_speed(), _ship.max_forward_speed])
	_ok("sitting on the astern ceiling the thrusters only hold against the glide",
		_ship.commanded_acceleration.length() < _ship.linear_drag
		* _ship.max_reverse_speed * 1.6 + 2.0,
		"commanded %.0f px/s^2 to keep %.0f px/s (the void takes %.0f)"
		% [_ship.commanded_acceleration.length(), _ship.max_reverse_speed,
		_ship.linear_drag * _ship.max_reverse_speed])
	Input.action_release("thrust_backward")
	await _wait(30)
	_ok("letting go of S leaves the ship coasting backwards",
		_speed() > _ship.velocity_stop_threshold and _ship.movement_mode
		== ShipController.Mode.IDLE, "%.0f px/s, %s" % [_speed(), _ship.mode_name()])
	var drifting := _speed()
	await _wait(60)
	_ok("the astern glide decays like any other", _speed() < drifting
		and _speed() > drifting * 0.7, "%.0f -> %.0f px/s" % [drifting, _speed()])


# ------------------------------------------------- test F. angular inertia -----

func _test_f_angular_inertia() -> void:
	_beat("test F angular inertia")
	await _park(CORRIDOR, 0.0)
	Input.action_press("turn_left")
	await _step()
	var first := absf(_ship.angular_velocity)
	_ok("the rudder starts below the exported rate and walks up to it",
		first * 60.0 < _ship.angular_acceleration,
		"first frame=%.3f rad/s, the verniers promise %.2f rad/s^2 at full power"
		% [first, _ship.angular_acceleration])
	await _wait(20)
	_ok("and it is the flight model's ramp that carries the rate up",
		absf(_ship.angular_velocity) > _ship.max_angular_speed * 0.6
		and absf(_ship.engines.rotation_power) > 0.99,
		"%.2f rad/s after 21 frames at power %.2f" % [_ship.angular_velocity,
		_ship.engines.rotation_power])
	_ok("a parked ship answers the rudder", first > 0.0 and _speed() < 1.0,
		"speed=%.2f px/s while yawing" % _speed())
	await _wait(30)
	var peak := absf(_ship.angular_velocity)
	var turned := _ship.rotation
	for i in 60:
		await _step()
		peak = maxf(peak, absf(_ship.angular_velocity))
		turned = minf(turned, _ship.rotation)
	Input.action_release("turn_left")
	_ok("A ramps the yaw rate in instead of snapping",
		first < _ship.max_angular_speed * 0.5,
		"first frame=%.2f of %.2f rad/s" % [first, _ship.max_angular_speed])
	_ok("A reaches the set rudder rate", peak >= _ship.max_angular_speed * 0.99,
		"peak=%.2f rad/s" % peak)
	_ok("A turns the nose to the left", turned < -1.5, "%.0f deg" % rad_to_deg(turned))
	_ok("the ramp is linear, not a jump onto an exponential",
		peak <= _ship.max_angular_speed * 1.001, "peak=%.3f rad/s" % peak)

	var still := absf(_ship.angular_velocity)
	var fading := 0
	var frames := 0
	while frames < 240 and absf(_ship.angular_velocity) > 0.0:
		await _step()
		frames += 1
		if absf(_ship.angular_velocity) > 0.0:
			fading += 1
	_ok("letting go does not cut the spin", still > _ship.max_angular_speed * 0.9,
		"%.2f rad/s on the frame the key came off" % still)
	_ok("the yaw bleeds off over the exported deceleration",
		fading > _ship.max_angular_speed / _ship.angular_deceleration * 60.0 * 0.7
		and fading < _ship.max_angular_speed / _ship.angular_deceleration * 60.0 * 1.6,
		"%.2f s of spin after release, %.2f rad/s^2 promises %.2f s"
		% [fading / 60.0, _ship.angular_deceleration,
		still / _ship.angular_deceleration])
	_ok("and it stops dead, not asymptotically", absf(_ship.angular_velocity) == 0.0,
		"%.4f rad/s left" % _ship.angular_velocity)
	_ok("the hull kept turning while the rate died away", turned < -2.0,
		"%.0f deg all together" % rad_to_deg(turned))


# ------------------------------------------------- test G. reversing the spin --

func _test_g_yaw_reversal() -> void:
	_beat("test G yaw reversal")
	await _park(CORRIDOR, 0.0)
	Input.action_press("turn_left")
	await _wait(90)
	var spinning := _ship.angular_velocity
	_ok("A really has the ship turning left",
		spinning < -_ship.max_angular_speed * 0.95, "%.2f rad/s" % spinning)
	Input.action_release("turn_left")
	Input.action_press("turn_right")
	var slowest_first := true
	var crossed := 0
	var biggest_step := 0.0
	var was := spinning
	for i in 200:
		await _step()
		var now := _ship.angular_velocity
		biggest_step = maxf(biggest_step, absf(now - was))
		if signf(now) != signf(was) and now != 0.0 and was != 0.0:
			crossed += 1
		# the rate has to climb toward zero before it climbs away from it
		if absf(now) > absf(was) and now < 0.0:
			slowest_first = false
		was = now
	Input.action_release("turn_right")
	_ok("the old spin is killed before the new one starts", slowest_first)
	_ok("the heading goes through zero exactly once", crossed == 1,
		"%d sign changes in 3.3 s" % crossed)
	_ok("the reversal is a ramp, not a flip",
		biggest_step <= maxf(_ship.angular_acceleration, _ship.angular_deceleration)
		/ 60.0 * 1.2, "biggest one-frame yaw change=%.3f rad/s" % biggest_step)
	_ok("and it settles on the opposite rudder", _ship.angular_velocity > 1.6,
		"%.2f rad/s" % _ship.angular_velocity)


# -------------------------------------------------- test H. several keys at once

func _test_h_simultaneous() -> void:
	_beat("test H simultaneous actions")
	var routine := [
		["thrust_forward", "turn_left"],
		["thrust_forward", "turn_right"],
		["thrust_backward", "turn_left"],
		["thrust_forward", "thrust_backward"],
		["thrust_backward", "turn_right"],
		["turn_left", "turn_right"],
		["thrust_forward", "thrust_backward", "turn_left"],
		[],
	]
	await _park(CORRIDOR, 0.0)
	# The stones are frozen walls, so a meeting changes the velocity in one frame -
	# that is what a collision is, and test I owns it. What this test owns is
	# whether the four levers can be flown together, so the arena is cleared for
	# the run and put back exactly as it was found.
	_clear_the_arena()
	var frames := 0
	var jumps := 0
	var fastest := 0.0
	var yaw_peak := 0.0
	var broken := 0
	var hardest := 0.0
	var was := _ship.linear_velocity
	while frames < 900:
		if frames % 40 == 0:
			_release_all()
			for a in routine[int(frames / 40.0) % routine.size()]:
				Input.action_press(a)
		await _step()
		frames += 1
		var now := _ship.linear_velocity
		var step := (now - was).length()
		hardest = maxf(hardest, step)
		if step > _ship.braking_acceleration / 60.0 * 1.6:
			jumps += 1
		was = now
		fastest = maxf(fastest, now.length())
		yaw_peak = maxf(yaw_peak, absf(_ship.angular_velocity))
		if not (_finite(_ship.global_position) and _finite(now)):
			broken += 1
	_release_all()
	_restore_the_arena()
	_ok("nothing broke", broken == 0, "%d non-finite frames" % broken)
	_ok("no combination flicks the velocity", jumps == 0,
		"hardest one-frame change=%.1f px/s, authority is %.1f"
		% [hardest, _ship.braking_acceleration / 60.0])
	_ok("speed stays inside the model", fastest <= _ship.max_forward_speed * 1.05,
		"peak %.0f of %.0f px/s" % [fastest, _ship.max_forward_speed])
	_ok("yaw stays inside the rudder", yaw_peak <= _ship.max_angular_speed * 1.02,
		"peak %.2f of %.2f rad/s" % [yaw_peak, _ship.max_angular_speed])
	_ok("the mode is always one of the four", _mode_is_sane(), _ship.mode_name())

	# W and S together: the retro burn is the stronger lever, so the ship keeps
	# speed it would otherwise have lost - but nothing about it is a step change.
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(180)
	var both_before := _speed()
	Input.action_press("thrust_backward")
	await _wait(60)
	var both_after := _speed()
	Input.action_release("thrust_backward")
	Input.action_release("thrust_forward")
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(180)
	var alone_before := _speed()
	Input.action_release("thrust_forward")
	Input.action_press("thrust_backward")
	await _wait(60)
	var alone_after := _speed()
	Input.action_release("thrust_backward")
	Input.action_release("thrust_forward")
	_ok("the engine is a real part of the answer, not ignored under S",
		both_after > alone_after * 1.15 and both_after < both_before,
		"both levers %.0f -> %.0f px/s, S alone %.0f -> %.0f"
		% [both_before, both_after, alone_before, alone_after])

	# opposite rudders cancel instead of fighting
	await _park(CORRIDOR, 0.0)
	Input.action_press("turn_left")
	Input.action_press("turn_right")
	await _wait(60)
	_ok("opposite rudders cancel to a held attitude",
		absf(_ship.angular_velocity) < 1e-6 and absf(_ship.rotation) < 1e-6,
		"yaw=%.6f rad/s, nose=%.6f rad" % [_ship.angular_velocity, _ship.rotation])
	Input.action_release("turn_left")
	Input.action_release("turn_right")


func _mode_is_sane() -> bool:
	return _ship.movement_mode >= ShipController.Mode.IDLE \
		and _ship.movement_mode <= ShipController.Mode.REVERSING


# ----------------------------------------- 9. what the ceilings are allowed to -

func _test_speed_caps() -> void:
	_beat("speed limits")
	await _park(CORRIDOR, 0.0)
	# earned faster than the ceiling on purpose: an engine cap is not a clamp, and
	# a hull thrown at 900 px/s by a bounce must not have speed shaved off it
	# because somebody is holding W.
	_ship.linear_velocity = _ship.forward() * 900.0 + Vector2(0, 400.0)
	Input.action_press("thrust_forward")
	var was_along := _ship.forward_speed()
	var was_across := _ship.drift_speed()
	await _wait(10)
	var decay := exp(-_ship.linear_drag * 10.0 / 60.0)
	_ok("W never shaves a faster glide down to the ceiling",
		_ship.forward_speed() > was_along * decay * 0.98
		and _ship.forward_speed() > _ship.max_forward_speed,
		"along %.0f -> %.0f px/s, ceiling %.0f" % [was_along, _ship.forward_speed(),
		_ship.max_forward_speed])
	_ok("and never eats the sideways component",
		absf(_ship.drift_speed()) > absf(was_across) * decay * 0.98,
		"across %.0f -> %.0f px/s" % [was_across, _ship.drift_speed()])
	Input.action_release("thrust_forward")
	await _wait(30)

	# the same the other way round: astern speed earned from outside stays put
	await _park(CORRIDOR, PI * 0.5)
	_ship.linear_velocity = _ship.forward() * -600.0
	Input.action_press("thrust_backward")
	await _wait(30)
	_ok("S does not clamp a faster tail-wind to the astern ceiling",
		_ship.forward_speed() < -_ship.max_reverse_speed * 1.5,
		"along=%.0f px/s, ceiling=%.0f" % [_ship.forward_speed(), _ship.max_reverse_speed])
	Input.action_release("thrust_backward")
	await _wait(60)

	# and a ship driven all the way up really does stop at the number
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	await _wait(400)
	_ok("the cruise ceiling is the exported number",
		absf(_ship.forward_speed() - _ship.max_forward_speed) < 3.0,
		"%.1f of %.1f px/s" % [_ship.forward_speed(), _ship.max_forward_speed])
	Input.action_release("thrust_forward")
	# lateral inertia survives a forward cruise: the drift a bounce put in stays
	await _park(CORRIDOR, 0.0)
	_ship.linear_velocity = Vector2(0, 300.0)
	Input.action_press("thrust_forward")
	await _wait(120)
	_ok("climbing on the engine keeps the drift that was already earned",
		absf(_ship.drift_speed()) > 300.0 * exp(-_ship.linear_drag * 2.0) * 0.95,
		"across=%.0f px/s after 2 s of W" % _ship.drift_speed())
	Input.action_release("thrust_forward")


# ------------------------------------------ 11. the switch that cuts the stick -

func _test_controls_switch() -> void:
	_beat("movement_enabled")
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	Input.action_press("turn_right")
	await _wait(30)
	_ok("the ship is flying before the cut", _speed() > 100.0, "%.0f px/s" % _speed())
	var coasted := _ship.linear_velocity.length()
	_ship.movement_enabled = false
	await _wait(60)
	_ok("movement_enabled=false takes the engines away",
		_ship.commanded_acceleration.length() < 1.0
		and _ship.movement_mode == ShipController.Mode.IDLE,
		"%s, commanded %.1f px/s^2" % [_ship.mode_name(),
		_ship.commanded_acceleration.length()])
	_ok("but leaves the momentum it already had",
		_speed() > coasted * 0.8, "%.0f -> %.0f px/s" % [coasted, _speed()])
	_ok("and the rudder is dead too", absf(_ship.angular_velocity) < 1e-6,
		"%.4f rad/s" % _ship.angular_velocity)
	Input.action_release("thrust_forward")
	Input.action_release("turn_right")
	_ship.movement_enabled = true
	Input.action_press("thrust_forward")
	Input.action_press("turn_right")
	await _wait(30)
	_ok("switching back on flies again",
		_ship.movement_mode == ShipController.Mode.FORWARD
		and _ship.angular_velocity > 0.1, "%.0f px/s, %s, yaw %.2f"
		% [_speed(), _ship.mode_name(), _ship.angular_velocity])
	_release_all()
	await _wait(30)


# ------------------------------------------------- test I. collisions ----------

func _test_i_collisions() -> void:
	_beat("test I collisions")
	var pebble: Node2D = _pick_smallest()
	var boulder: Node2D = _pick_largest()

	# a full-speed ram at the smallest stone has to stop at its surface
	await _park_aimed(pebble.global_position + Vector2(0, 1550), pebble.global_position)
	_ship.linear_velocity = Vector2(0, -_ship.max_forward_speed)
	var impact := _speed()
	var hits_before := _hits
	Input.action_press("thrust_forward")
	var frames := 0
	while frames < 240 and _hits == hits_before:
		await _step()
		frames += 1
	Input.action_release("thrust_forward")
	var touched := _hits > hits_before
	await _wait(20)
	_ok("the ship cannot pass through a rock", touched,
		"contact after %.2f s at %.0f px/s" % [frames / 60.0, impact])
	_ok("the meeting changed the ship's motion", _speed() < impact * 0.85,
		"%.0f -> %.0f px/s" % [impact, _speed()])
	# which way it went matters more than how fast: a hull that stops dead on a
	# pebble is stuck to it, a hull that comes back is a ship in space
	var away := _ship.linear_velocity.dot(
		_ship.global_position.direction_to(pebble.global_position))
	_ok("the ship comes off the stone instead of dead-stopping", away < -20.0,
		"%.0f px/s away from the rock" % away)
	_ok("the hull stayed on the side it came from",
		_ship.global_position.y > pebble.global_position.y - pebble.extent,
		"dy=%.0f px, reach=%.0f" % [pebble.global_position.y - _ship.global_position.y,
		pebble.extent])
	_ok("the speed a contact left behind is what the model starts from",
		_speed() > 20.0, "%.0f px/s still moving after the meeting" % _speed())

	# leaned on a boulder the ship has to stay outside it, and come free again on
	# the retro burn. The meeting is an oscillation - the hull bounces, the engine
	# walks it back - so the numbers are the worst frame of the lean, not one
	# frame picked by a stopwatch.
	await _park_aimed(boulder.global_position + Vector2(560, 0), boulder.global_position)
	Input.action_press("thrust_forward")
	var closest := INF
	var lean := 0
	while lean < 300 and closest > boulder.extent + 180.0:
		await _step()
		lean += 1
		closest = minf(closest, boulder.global_position.distance_to(_ship.global_position))
	var worst_clearance := _clearance()
	for i in 90:
		await _step()
		closest = minf(closest, boulder.global_position.distance_to(_ship.global_position))
		worst_clearance = minf(worst_clearance, _clearance())
	Input.action_release("thrust_forward")
	_ok("the ship reaches the boulder and leans on it",
		closest < boulder.extent + 180.0,
		"closed to %.0f px of a %.0f px reach in %.1f s" % [closest, boulder.extent,
		lean / 60.0])
	_ok("held against a rock the ship stays outside it",
		worst_clearance >= SINK, "worst clearance during the lean=%.1f px" % worst_clearance)
	var pressed_at := boulder.global_position.distance_to(_ship.global_position)
	Input.action_press("thrust_backward")
	await _wait(150)
	Input.action_release("thrust_backward")
	var freed := boulder.global_position.distance_to(_ship.global_position)
	_ok("the ship backs free and does not stick",
		freed > pressed_at + 60.0 and _clearance() >= SINK,
		"%.0f -> %.0f px off the boulder" % [pressed_at, freed])

	# a flat face met at an angle: slide along it, never through it
	await _park_aimed(Vector2(-650, _wall.global_position.y + 800),
		Vector2(50, _wall.global_position.y))
	Input.action_press("thrust_forward")
	var slid := 0.0
	var was_x := _ship.global_position.x
	var face := _wall.global_position.y + _wall_half.y
	var below := true
	for i in 150:
		await _step()
		slid = maxf(slid, absf(_ship.global_position.x - was_x))
		below = below and _ship.global_position.y > face
	Input.action_release("thrust_forward")
	_ok("the wall is solid", below and _clearance() >= SINK,
		"hull centre stayed at y=%.0f, face at y=%.0f" % [_ship.global_position.y, face])
	_ok("hitting a wall at an angle sends the ship along it",
		slid > 150.0 and absf(_ship.linear_velocity.x) > 80.0,
		"%.0f px sideways at %.0f px/s" % [slid, absf(_ship.linear_velocity.x)])

	# and a hard hit does not leave the controller with a speed it cannot fly with
	await _park_aimed(boulder.global_position + Vector2(0, 1600), boulder.global_position)
	_ship.linear_velocity = Vector2(0, -_ship.max_forward_speed)
	Input.action_press("thrust_forward")
	await _wait(150)
	Input.action_release("thrust_forward")
	await _wait(60)
	_ok("the physics is still sane after the hardest hit in the map",
		_finite(_ship.global_position) and _speed() < _ship.max_forward_speed * 1.6
		and _clearance() >= SINK, "pos=%s speed=%.0f px/s clearance=%.1f"
		% [str(_ship.global_position), _speed(), _clearance()])


# ------------------------------------------------ 12. camera compatibility -----

func _test_camera() -> void:
	_beat("camera")
	await _park(CORRIDOR, 0.0)
	await _wait(60)
	_ok("camera settles on the ship",
		_cam.global_position.distance_to(_ship.global_position) < 1.0,
		"gap=%.2f px" % _cam.global_position.distance_to(_ship.global_position))
	var centre: Vector2 = _cam.get_screen_center_position() - _ship.global_position
	_ok("the ship sits in the middle of the frame", centre.length() < 2.0,
		"screen centre off by %.2f px" % centre.length())

	Input.action_press("thrust_forward")
	var biggest_step := 0.0
	var was := _cam.global_position
	for i in 150:
		await _step()
		biggest_step = maxf(biggest_step, _cam.global_position.distance_to(was))
		was = _cam.global_position
	var lag := _cam.global_position.distance_to(_ship.global_position)
	Input.action_release("thrust_forward")
	_ok("camera trails the ship smoothly rather than locking to it",
		lag > 1.0 and lag < 200.0, "lagging %.0f px at cruise" % lag)
	_ok("the view never jerks", biggest_step < _ship.max_forward_speed / 60.0 * 3.0,
		"biggest camera step=%.1f px in one frame" % biggest_step)

	# and when the ship is brought to a standstill, the gap closes for good
	Input.action_press("thrust_backward")
	var guard := 0
	while guard < 300 and _speed() > 20.0:
		await _step()
		guard += 1
	Input.action_release("thrust_backward")
	await _wait(120)
	var resting := _cam.global_position.distance_to(_ship.global_position)
	_ok("camera re-centres once the ship is stopped", resting < 3.0,
		"%.2f px of lag left after braking (%.0f px at cruise)" % [resting, lag])

	await _park(CORRIDOR, 0.0)
	Input.action_press("turn_right")
	var spun := 0.0
	for i in 90:
		await _step()
		spun = maxf(spun, absf(_ship.rotation))
	Input.action_release("turn_right")
	_ok("the horizon stays level while the ship yaws",
		spun > 1.0 and absf(_cam.global_rotation) < 0.001,
		"ship %.0f deg, camera %.4f rad" % [rad_to_deg(spun), _cam.global_rotation])

	var before := _cam.zoom.x
	for i in 3:
		_cam.zoom_in()
	await _wait(90)
	_ok("the view pulls in", _cam.zoom.x > before * 1.2,
		"%.2f -> %.2f" % [before, _cam.zoom.x])
	for i in 24:
		_cam.zoom_out()
	await _wait(150)
	_ok("zoom reaches the widest look around and stops there",
		absf(_cam.zoom.x - _cam.min_zoom) < 0.02,
		"%.2f of %.2f" % [_cam.zoom.x, _cam.min_zoom])
	for i in 40:
		_cam.zoom_in()
	await _wait(200)
	_ok("zoom stops at the closest inspection",
		absf(_cam.zoom.x - _cam.max_zoom) < 0.05,
		"%.2f of %.2f" % [_cam.zoom.x, _cam.max_zoom])

	# the wheel is the pilot's entry point for all of that, and it has to work
	# from a view that is not already sitting on a clamp
	_cam.set_view_zoom(_cam.base_zoom)
	await _wait(90)
	var wheel := _cam.zoom.x
	var notch := InputEventMouseButton.new()
	notch.button_index = MOUSE_BUTTON_WHEEL_DOWN
	notch.pressed = true
	root.push_input(notch)
	root.push_input(notch)
	await _wait(90)
	_ok("the mouse wheel reaches the camera", _cam.zoom.x < wheel - 0.01,
		"%.2f -> %.2f after two wheel-down notches" % [wheel, _cam.zoom.x])
	_ok("the camera is not part of the physics", _cam.top_level
		and not _cam.position_smoothing_enabled,
		"top_level=%s own smoothing=%s" % [_cam.top_level, _cam.position_smoothing_enabled])
	_cam.set_view_zoom(_cam.base_zoom)
	await _wait(60)


# ------------------------------------------------------- 13. diagnostics -------

func _test_diagnostics() -> void:
	_beat("diagnostics")
	await _park(CORRIDOR, 0.0)
	_ok("diagnostics start switched off", not _ship.show_debug and not _debug.visible,
		"visible=%s" % str(_debug.visible))
	_ship.show_debug = true
	await process_frame
	await _wait(2)
	_ok("show_debug puts the overlay up", _debug.visible, str(_debug.visible))
	_ok("the overlay rides the hull without spinning with it", _debug.top_level,
		"top_level=%s at %s" % [_debug.top_level, str(_debug.global_position)])
	Input.action_press("thrust_forward")
	Input.action_press("turn_left")
	await _wait(30)
	var lines := _debug.readout()
	var text := "\n".join(lines)
	_ok("the readout names the mode", text.contains("FORWARD")
		or text.contains("BRAKING"), lines[0])
	_ok("it prints every number the stage is asked to show",
		text.contains("mode") and text.contains("speed") and text.contains("velocity")
		and text.contains("along") and text.contains("across") and text.contains("nose")
		and text.contains("accel") and text.contains("yaw") and text.contains("position"),
		"%d lines" % lines.size())
	_ok("the speed line is the ship's own speed", lines.size() > 1
		and lines[1].contains("%.0f" % _speed()), lines[1])
	_ok("the yaw line is the ship's own yaw", lines.size() > 7
		and lines[7].contains("%.2f" % _ship.angular_velocity), lines[7])
	Input.action_release("turn_left")
	Input.action_release("thrust_forward")
	Input.action_press("thrust_backward")
	await _wait(10)
	_ok("the readout follows the burn the pilot is asking for",
		_debug.readout()[0].contains("BRAKING"), _debug.readout()[0])
	Input.action_release("thrust_backward")
	_ship.show_debug = false
	await process_frame
	await _wait(2)
	_ok("switching off takes it back down", not _debug.visible, str(_debug.visible))

	# The real question about a diagnostics layer is whether the ship can tell it
	# is there: the same burn, once watched and once not, has to come out of the
	# physics server with the same numbers.
	_ship.show_debug = false
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	Input.action_press("turn_left")
	await _wait(60)
	var blind := [_ship.linear_velocity.x, _ship.linear_velocity.y, _ship.rotation,
		_ship.angular_velocity]
	Input.action_release("thrust_forward")
	Input.action_release("turn_left")
	_ship.show_debug = true
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	Input.action_press("turn_left")
	await _wait(60)
	var watched := [_ship.linear_velocity.x, _ship.linear_velocity.y, _ship.rotation,
		_ship.angular_velocity]
	Input.action_release("thrust_forward")
	Input.action_release("turn_left")
	_ship.show_debug = false
	await _wait(2)
	_ok("the flight does not notice the overlay", blind == watched,
		"blind %s, watched %s" % [str(blind), str(watched)])


## The same burn at three physics rates. Nothing in the controller may care how
## the seconds are cut up: the glide is exponential in delta, every ramp is
## `rate * delta`, and the position is the engine's business - so the three runs
## have to land on the same speed and the same ground.
func _flight_at(rate: int) -> Array:
	var was := Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = rate
	await _park(CORRIDOR, 0.0)
	Input.action_press("thrust_forward")
	Input.action_press("turn_left")
	# Two seconds of flight, counted in the deltas the engine actually handed out
	# rather than in steps: asking for 30 Hz is not the same as getting it, and a
	# rate test that assumes the rate is a test of the clock, not of the model.
	var sim := 0.0
	var steps := 0
	while sim < 2.0 and steps < 600:
		await _step()
		sim += _ship.get_physics_process_delta_time()
		steps += 1
	var out := [_speed(), _ship.forward_speed(), _ship.drift_speed(),
		absf(_ship.angular_velocity), _ship.global_position.length(), sim, steps]
	Input.action_release("thrust_forward")
	Input.action_release("turn_left")
	Engine.physics_ticks_per_second = was
	await _park(CORRIDOR, 0.0)
	return out


func _test_frame_rate_independence() -> void:
	_beat("frame rate independence", 13000)
	# no stones in the way: this is about how the integrator cuts the second up,
	# and a bounce at 30 Hz is not the same bounce as at 120
	_clear_the_arena()
	var slow := await _flight_at(30)
	var normal := await _flight_at(60)
	var fast := await _flight_at(120)
	_restore_the_arena()
	var clock := "clock %.0f/%.0f/%.0f Hz over %.2f/%.2f/%.2f s in %d/%d/%d steps" % [
		float(slow[6]) / maxf(slow[5], 0.001), float(normal[6]) / maxf(normal[5], 0.001),
		float(fast[6]) / maxf(fast[5], 0.001), slow[5], normal[5], fast[5],
		int(slow[6]), int(normal[6]), int(fast[6])]
	_ok("the three runs really are the same two seconds",
		absf(slow[5] - 2.0) < 0.12 and absf(normal[5] - 2.0) < 0.12
		and absf(fast[5] - 2.0) < 0.12, clock)
	_ok("the burn lands on the same speed whatever the rate",
		_close(slow[0], normal[0]) and _close(fast[0], normal[0]),
		"speed %.1f / %.1f / %.1f px/s" % [slow[0], normal[0], fast[0]])
	_ok("the yaw rate does not care how the second is cut",
		_close(slow[3], normal[3]) and _close(fast[3], normal[3]),
		"yaw %.3f / %.3f / %.3f rad/s" % [slow[3], normal[3], fast[3]])
	_ok("and the ground covered is the same flight, not three of them",
		_close(slow[4], normal[4], 0.12) and _close(fast[4], normal[4], 0.12),
		"%.0f / %.0f / %.0f px from the origin" % [slow[4], normal[4], fast[4]])
	_ok("the physics clock came back to 60 Hz",
		Engine.physics_ticks_per_second == 60, str(Engine.physics_ticks_per_second))


## Within `tol` of the reference, relatively.
func _close(value: float, reference: float, tol := 0.03) -> bool:
	if reference == 0.0:
		return absf(value) < 1e-6
	return absf(value - reference) <= absf(reference) * tol


# --------------------------------------------------- test J. a long flight -----

func _test_j_endurance() -> void:
	_beat("test J endurance")
	await _park(CORRIDOR, 0.0)
	# a fixed routine rather than noise, so any failure can be replayed exactly
	var routine := [["thrust_forward"], ["thrust_forward", "turn_left"], ["turn_right"],
		["thrust_backward"], [], ["thrust_forward", "turn_right"], ["turn_left"],
		["thrust_backward", "turn_right"]]
	var frames := 0
	var fastest := 0.0
	var broken := 0
	var flown := 0.0
	var jitter := 0
	var creep := 0
	var was := _ship.global_position
	var was_speed := 0.0
	while frames < 1400:
		if frames % 45 == 0:
			_release_all()
			for a in routine[int(frames / 45.0) % routine.size()]:
				Input.action_press(a)
		await _step()
		frames += 1
		flown += was.distance_to(_ship.global_position)
		was = _ship.global_position
		var now := _speed()
		fastest = maxf(fastest, now)
		# creep is what a broken stop looks like: a few px/s swapping sign a
		# frame apart, forever, with nothing pressed
		if _ship.movement_mode == ShipController.Mode.IDLE and now < 30.0 \
				and _ship.get_contact_count() == 0:
			if absf(now - was_speed) > 6.0:
				jitter += 1
			if now > 0.0 and frames % 45 > 20:
				creep += 1
		was_speed = now
		if not (_finite(_ship.global_position) and _finite(_ship.linear_velocity)):
			broken += 1
	_ok("a long flight stays physical", broken == 0
		and fastest < _ship.max_forward_speed * 1.6,
		"%d frames, %.0f px flown, top speed %.0f of cap %.0f"
		% [frames, flown, fastest, _ship.max_forward_speed])
	_ok("no jitter at low speed", jitter == 0, "%d jittery frames" % jitter)
	_release_all()

	# bring her down with the brakes, then let the void finish the job
	Input.action_press("thrust_backward")
	var guard := 0
	while guard < 400 and _speed() > 20.0:
		await _step()
		guard += 1
	Input.action_release("thrust_backward")
	await _wait(420)
	_ok("the ship settles all the way down and stays there",
		_speed() == 0.0 and _ship.angular_velocity == 0.0,
		"end position=%s speed=%.2f yaw=%.4f" % [str(_ship.global_position),
		_speed(), _ship.angular_velocity])
	var parked := _ship.global_position
	await _wait(180)
	_ok("and is genuinely parked, not creeping",
		_ship.global_position.distance_to(parked) < 0.01
		and _ship.movement_mode == ShipController.Mode.IDLE,
		"%.3f px moved in 3 s, %d frames of idle creep" % [
		_ship.global_position.distance_to(parked), creep])
	if _sky != null:
		var st: Dictionary = _sky.stats()
		_ok("the sky is still streaming where the long flight ended",
			int(st.nodes) > 20, "%s at %s" % [str(st), str(_ship.global_position)])


func _finite(v: Vector2) -> bool:
	return is_finite(v.x) and is_finite(v.y)
