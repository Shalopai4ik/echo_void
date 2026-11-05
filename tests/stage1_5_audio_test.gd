extends SceneTree

## Sub-stage 1.5 verification: the ship's audio, the mixer that carries it, the debug
## overlay, and a measured pass over the flight envelope.
## Run: godot --headless --path . --script tests/stage1_5_audio_test.gd
##
## Three claims this suite exists to hold:
##
## - **A sound is a power, not a key.** Every layer assertion is made against the
##   engine plant's own power on the same frame, so a layer that followed the input
##   instead of the physics would fail here.
## - **No file, no error.** The project ships without audio today, and the suite is
##   written to pass in that state: the rate limiter, the classification and the
##   smoothing are all tested through their *intent* counters, not through playback.
## - **The hull still flies the same.** The balance phase measures acceleration,
##   coast, turn, strafe, braking and boost against the exported parameters, so a
##   tuning change that broke the feel would be visible as a number, not as an
##   opinion.

const MAP := "res://scenes/test/TestControlMap.tscn"
const CORRIDOR := Vector2(0.0, 1000.0)
const STONE_AT := Vector2(1400.0, 1000.0)
## Far enough that no measurement can accidentally touch a rock.
const PARKED_ROCK := Vector2(0.0, 38000.0)
const PHASE_STEPS := 6000
## How many voices and layers the component is expected to own. Pinned here so a
## change that starts creating players per event fails loudly.
const LOOP_PLAYERS := 6
const VOICE_PLAYERS := 8

var _ship: ShipController
var _plant: EngineController
var _audio: ShipAudio
var _debug: ShipDebug
var _world: ShipWorldParameters
var _rocks: Array = []
var _stone = null

var _checks := 0
var _failed := 0
var _phase := "boot"
var _steps_at_start := 0
var _played: Array[String] = []


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
	_debug = _ship.get_node("FlightDebug") as ShipDebug
	_audio = _ship.get_node_or_null("Audio") as ShipAudio
	_rocks = get_nodes_in_group("obstacle")
	if _audio != null:
		_audio.sound_event.connect(_on_sound)
	await process_frame
	await physics_frame
	_clear_arena()

	_beat("mixer and component")
	_test_mixer()
	_test_component()
	await _test_engine_layer()
	await _test_retro_and_strafe()
	await _test_boost()
	await _test_stabilizer_and_emergency()
	await _test_collisions()
	await _test_control_and_switch()
	await _test_panel_and_toggle()
	await _test_endurance()
	await _test_relaunch()
	await _test_balance()
	_restore_arena()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0
		else "ALL PASS")
	quit(1 if _failed > 0 else 0)


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


## One idle frame and one physics frame. Audio is smoothed in `_process`, so a test
## that only awaited `physics_frame` would read levels that never moved.
func _tick() -> void:
	await process_frame
	await physics_frame


func _wait(frames: int) -> void:
	for i in frames:
		await _tick()


func _phys(frames: int) -> void:
	for i in frames:
		await _step()


func _release_all() -> void:
	for action in ["thrust_forward", "thrust_backward", "strafe_left", "strafe_right",
			"turn_left", "turn_right", "toggle_stabilization", "emergency_brake",
			"boost", "toggle_debug"]:
		Input.action_release(action)


func _on_sound(event_name: String, _db: float) -> void:
	_played.append(event_name)


func _counts() -> int:
	var total := 0
	if _audio == null:
		return total
	for event_name in ShipAudio.event_names():
		total += _audio.event_count(event_name)
	return total


func _place(at: Vector2, heading := 0.0) -> void:
	# The hull is a RigidBody2D, and a rigid body belongs to the physics server:
	# writing `rotation` or `global_position` on the node is thrown away on the
	# next physics step, so the server hands back the attitude it last simulated.
	# The heading and the parking spot therefore have to go through the server
	# state - otherwise every phase starts from whatever angle the previous one
	# left behind, and a nose-ward speed reads negative before the ship has done
	# anything at all.
	var xform := Transform2D(heading, at)
	PhysicsServer2D.body_set_state(_ship.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, xform)
	_ship.global_transform = xform
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0


## Hold the hull still until every ramp has bled off. The plant's powers fall over
## their own shutdown times and the boost factor over its own ramp, so "parked" has
## to mean all three, not just a zero velocity written once.
func _park(heading := 0.0) -> void:
	_release_all()
	_ship.movement_enabled = true
	var guard := 0
	while guard < 400:
		_place(CORRIDOR, heading)
		await _tick()
		var quiet := _plant.total_load() <= 0.001 \
			and _ship.external_acceleration.length_squared() == 0.0
		if _ship.boost != null and _ship.boost.factor > 1.001:
			quiet = false
		# The mixer lags the plant by its own fade, so a hull is not parked for this
		# suite until the hum has actually reached silence.
		if _audio != null and _audio.level(ShipAudio.LAYER_MAIN) >= 0.01:
			quiet = false
		if quiet:
			break
		guard += 1
	_place(CORRIDOR, heading)
	await _tick()


func _clear_arena() -> void:
	for rock in _rocks:
		if is_instance_valid(rock):
			rock.global_position = PARKED_ROCK


func _restore_arena() -> void:
	_clear_arena()


## Put one stone in the hull's path and hand it back.
func _stone_ahead(at: Vector2 = STONE_AT) -> void:
	_stone = _rocks[0]
	_stone.global_position = at
	_stone.linear_velocity = Vector2.ZERO
	_stone.angular_velocity = 0.0


## Fly into the stone at `speed`, then wait for the audio component to accept a
## contact. Returns true when at least one impact was raised.
func _ram_stone(speed: float) -> bool:
	_ship.global_position = STONE_AT - Vector2.RIGHT * 500.0
	_ship.rotation = 0.0
	_ship.angular_velocity = 0.0
	_ship.linear_velocity = Vector2.RIGHT * speed
	await _step()
	_ship.linear_velocity = Vector2.RIGHT * speed
	await _step()
	var before := _counts()
	var guard := 0
	while guard < 400 and _counts() == before:
		await _step()
		guard += 1
	return _counts() > before


# --------------------------------------------------------------- 1. the mixer --

func _test_mixer() -> void:
	for bus in AudioMixer.ALL:
		_ok("bus %s exists" % bus, AudioMixer.has_bus(bus),
			"index %d" % AudioServer.get_bus_index(bus))
	_ok("the engine layers hang off Ship",
		String(AudioServer.get_bus_send(AudioMixer.index(AudioMixer.SHIP_ENGINES)))
		== "Ship"
		and String(AudioServer.get_bus_send(AudioMixer.index(AudioMixer.SHIP_SYSTEMS)))
		== "Ship"
		and String(AudioServer.get_bus_send(AudioMixer.index(AudioMixer.SHIP_IMPACTS)))
		== "Ship",
		"ShipEngines/ShipSystems/ShipImpacts -> Ship")
	_ok("the ship itself is a child of Master",
		String(AudioServer.get_bus_send(AudioMixer.index(AudioMixer.SHIP))) == "Master"
		and String(AudioServer.get_bus_send(AudioMixer.index(AudioMixer.AMBIENCE)))
		== "Master",
		"Ship/Ambience -> Master")
	# The knobs a settings menu will drive. Set, read back, restore.
	var before := AudioMixer.volume_linear(AudioMixer.SHIP_ENGINES)
	AudioMixer.set_volume_linear(AudioMixer.SHIP_ENGINES, 0.5)
	_ok("a bus volume can be set and read as 0..1",
		absf(AudioMixer.volume_linear(AudioMixer.SHIP_ENGINES) - 0.5) < 0.02,
		"%.2f" % AudioMixer.volume_linear(AudioMixer.SHIP_ENGINES))
	AudioMixer.set_volume_linear(AudioMixer.SHIP_ENGINES, before)
	AudioMixer.set_muted(AudioMixer.SHIP_IMPACTS, true)
	_ok("a bus can be muted, and comes back",
		AudioMixer.is_muted(AudioMixer.SHIP_IMPACTS),
		str(AudioMixer.is_muted(AudioMixer.SHIP_IMPACTS)))
	AudioMixer.set_muted(AudioMixer.SHIP_IMPACTS, false)


func _test_component() -> void:
	_ok("the ship carries an audio component", _audio != null)
	if _audio == null:
		return
	_ok("one player per layer and one fixed voice pool",
		_audio.get_child_count() == LOOP_PLAYERS + VOICE_PLAYERS,
		"%d children" % _audio.get_child_count())
	_ok("the component declares the six layers the spec asks for",
		ShipAudio.layer_names().size() == LOOP_PLAYERS, str(ShipAudio.layer_names()))
	_ok("and the collision and system events",
		ShipAudio.event_names().size() == 13
		and ShipAudio.event_names().has(ShipAudio.EVENT_IMPACT_HEAVY)
		and ShipAudio.event_names().has(ShipAudio.EVENT_BOOST_EMPTY),
		str(ShipAudio.event_names()))
	_ok("the stream inventory always adds up",
		_audio.loaded_streams() + _audio.missing_streams().size()
		== _audio.total_streams(),
		"%d loaded, %d missing, %d total" % [_audio.loaded_streams(),
			_audio.missing_streams().size(), _audio.total_streams()])
	_ok("the master switch starts on", _audio.enabled, str(_audio.enabled))
	_ok("the hull announced that it is up",
		_audio.event_count(ShipAudio.EVENT_POWER_ON) >= 1,
		"%d intent(s)" % _audio.event_count(ShipAudio.EVENT_POWER_ON))
	var off_bus := 0
	for layer in ShipAudio.layer_names():
		var player := _audio.layer_player(layer)
		if player == null or not AudioMixer.has_bus(player.bus):
			off_bus += 1
	_ok("every layer sits on a bus that exists", off_bus == 0,
		"%d layers off-bus" % off_bus)
	# Honest inventory: with no files in the project this is zero, and the report says so.
	print("  streams on disk: %d of %d   missing: %s" % [_audio.loaded_streams(),
		_audio.total_streams(), str(_audio.missing_streams())])


# ------------------------------------------------------------- 2. the layers --

## Wait until a predicate holds, ticking idle and physics together. Bounded, so a
## broken ramp fails a check instead of hanging the suite.
func _until(predicate: Callable, cap: int) -> bool:
	for i in cap:
		if predicate.call():
			return true
		await _tick()
	return bool(predicate.call())


func _test_engine_layer() -> void:
	_beat("the main layer follows the plant, not the key")
	await _park()
	_ok("a parked hull's main layer is silent",
		_audio.level(ShipAudio.LAYER_MAIN) < 0.01,
		"%.3f" % _audio.level(ShipAudio.LAYER_MAIN))
	Input.action_press("thrust_forward")
	# The plant has to reach its own full power first; the layer follows it.
	var spooled := await _until(func() -> bool: return _plant.main_power > 0.95, 180)
	_ok("the plant reached full power", spooled,
		"main_power %.2f" % _plant.main_power)
	var raised := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_MAIN) > 0.97, 240)
	_ok("the main layer caught up with it with no file present", raised,
		"level %.2f after a %.2f s ramp" % [_audio.level(ShipAudio.LAYER_MAIN),
			_audio.settings().engine_fade_time])
	var gap := absf(_audio.level(ShipAudio.LAYER_MAIN) - _plant.main_power)
	_ok("the level and the power are the same number", gap < 0.15,
		"level %.2f vs power %.2f" % [_audio.level(ShipAudio.LAYER_MAIN),
			_plant.main_power])
	# A cut would go from full to zero in one frame; the fade must not.
	Input.action_release("thrust_forward")
	await _tick()
	var after_release := _audio.level(ShipAudio.LAYER_MAIN)
	_ok("releasing W does not cut the hum off",
		after_release > 0.5, "%.2f one frame after release" % after_release)
	var hushed := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_MAIN) < 0.02, 300)
	_ok("and it fades to silence instead", hushed,
		"%.3f" % _audio.level(ShipAudio.LAYER_MAIN))
	_ok("the player is stopped once it is inaudible",
		not _audio.layer_player(ShipAudio.LAYER_MAIN).playing,
		str(_audio.layer_player(ShipAudio.LAYER_MAIN).playing))


func _test_retro_and_strafe() -> void:
	_beat("brake, astern, strafe and yaw each have their own layer")
	await _park()
	_ship.linear_velocity = Vector2(600.0, 0.0)
	Input.action_press("thrust_backward")
	var braking := await _until(
		func() -> bool: return _plant.brake_power > 0.9, 120)
	_ok("the retro plant answers S", braking,
		"brake_power %.2f" % _plant.brake_power)
	var retro_up := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_RETRO) > 0.7, 180)
	_ok("the retro layer follows the brake power", retro_up,
		"level %.2f vs power %.2f" % [_audio.level(ShipAudio.LAYER_RETRO),
			_plant.brake_power])
	_release_all()
	await _until(func() -> bool: return _audio.level(ShipAudio.LAYER_RETRO) < 0.02, 300)

	await _park()
	Input.action_press("thrust_backward")
	var astern := await _until(
		func() -> bool: return _plant.astern_power > 0.8, 180)
	_ok("S from a standstill lights the astern group on the same layer", astern,
		"astern_power %.2f, retro level %.2f" % [_plant.astern_power,
			_audio.level(ShipAudio.LAYER_RETRO)])
	_release_all()
	await _until(func() -> bool: return _audio.level(ShipAudio.LAYER_RETRO) < 0.02, 300)

	await _park()
	Input.action_press("strafe_right")
	var strafe_up := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_STRAFE) > 0.5, 180)
	_ok("E lights the manoeuvring layer", strafe_up,
		"level %.2f vs power %.2f" % [_audio.level(ShipAudio.LAYER_STRAFE),
			absf(_plant.strafe_power)])
	Input.action_release("strafe_right")

	Input.action_press("turn_left")
	var turn_up := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_ROTATION) > 0.5, 180)
	_ok("A lights the yaw verniers", turn_up,
		"level %.2f vs power %.2f" % [_audio.level(ShipAudio.LAYER_ROTATION),
			absf(_plant.rotation_power)])
	_release_all()
	var quiet := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_STRAFE) < 0.02 and _audio.level(ShipAudio.LAYER_ROTATION) < 0.02,
		180)
	_ok("the manoeuvring layers fade back to silence", quiet,
		"slide %.2f turn %.2f" % [_audio.level(ShipAudio.LAYER_STRAFE),
			_audio.level(ShipAudio.LAYER_ROTATION)])


# ---------------------------------------------------------------- 3. the boost --

func _test_boost() -> void:
	_beat("boost raises the engine and announces its tank")
	await _park()
	_ship.boost.set_charge(1.0)
	var on_before := _audio.event_count(ShipAudio.EVENT_BOOST_ON)
	var low_before := _audio.event_count(ShipAudio.EVENT_BOOST_LOW)
	var empty_before := _audio.event_count(ShipAudio.EVENT_BOOST_EMPTY)
	var ready_before := _audio.event_count(ShipAudio.EVENT_BOOST_READY)

	Input.action_press("thrust_forward")
	await _until(func() -> bool: return _plant.main_power > 0.95, 180)
	Input.action_press("boost")
	var lit := await _until(
		func() -> bool: return _ship.boost.active and _ship.boost.factor > 1.6, 180)
	_ok("the boost lit and ramped its authority", lit,
		"active %s factor %.2f" % [str(_ship.boost.active), _ship.boost.factor])
	_ok("the plant is authorised past its ordinary ceiling",
		_plant.main_power > 1.05, "main_power %.2f" % _plant.main_power)
	var boost_up := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_BOOST) > 0.6, 180)
	_ok("the boost layer follows the factor", boost_up,
		"level %.2f" % _audio.level(ShipAudio.LAYER_BOOST))
	var over := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_MAIN) > 1.0, 180)
	_ok("the main layer is allowed past 1.0 under boost", over,
		"level %.2f vs power %.2f" % [_audio.level(ShipAudio.LAYER_MAIN),
			_plant.main_power])
	_ok("boost_on fired exactly once", _audio.event_count(ShipAudio.EVENT_BOOST_ON)
		== on_before + 1, "%d -> %d" % [on_before,
			_audio.event_count(ShipAudio.EVENT_BOOST_ON)])
	_ok("and it was reported on the sound_event line",
		_played.has(ShipAudio.EVENT_BOOST_ON), str(_played))

	# Release the lever: the layer has to ramp out with the factor, not stop dead.
	Input.action_release("boost")
	await _tick()
	var after_release := _audio.level(ShipAudio.LAYER_BOOST)
	_ok("releasing boost does not cut the layer off",
		after_release > 0.2, "%.2f one frame after release" % after_release)
	var settled := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_BOOST) < 0.02, 300)
	_ok("it settles back to the ordinary engine", settled,
		"%.3f" % _audio.level(ShipAudio.LAYER_BOOST))
	Input.action_release("thrust_forward")
	await _park()

	# The tank's three announcements. Start just under the low threshold, burn to
	# dry, then let it recover past the ready level.
	_ship.boost.set_charge(0.26)
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	var low := await _until(
		func() -> bool: return _audio.event_count(ShipAudio.EVENT_BOOST_LOW) > low_before,
		180)
	_ok("a quarter tank announces itself", low,
		"%.2f left" % _ship.boost.boost_charge)
	var empty := await _until(
		func() -> bool: return _audio.event_count(ShipAudio.EVENT_BOOST_EMPTY) > empty_before,
		600)
	_ok("running dry announces itself", empty,
		"%.3f left, reason %s" % [_ship.boost.boost_charge, _ship.boost.reason])
	_ok("the tank really is empty", _ship.boost.boost_charge <= 0.01,
		"%.3f" % _ship.boost.boost_charge)
	Input.action_release("boost")
	Input.action_release("thrust_forward")
	var ready := await _until(
		func() -> bool: return _audio.event_count(ShipAudio.EVENT_BOOST_READY) > ready_before,
		1200)
	_ok("the tank coming back is announced", ready,
		"%.2f recovered" % _ship.boost.boost_charge)
	_ok("and it recovered at least to the ready level",
		_ship.boost.boost_charge >= _audio.settings().boost_ready_charge,
		"%.2f vs %.2f" % [_ship.boost.boost_charge,
			_audio.settings().boost_ready_charge])
	_ok("the three tank announcements did not stack",
		_audio.event_count(ShipAudio.EVENT_BOOST_LOW) == low_before + 1
		and _audio.event_count(ShipAudio.EVENT_BOOST_EMPTY) == empty_before + 1,
		"low %d, empty %d" % [_audio.event_count(ShipAudio.EVENT_BOOST_LOW),
			_audio.event_count(ShipAudio.EVENT_BOOST_EMPTY)])


# ------------------------------------------------- 4. the switch and the lever --

func _test_stabilizer_and_emergency() -> void:
	_beat("stabilization toggles and the emergency brake announces itself")
	await _park()
	var on_before := _audio.event_count(ShipAudio.EVENT_STAB_ON)
	var off_before := _audio.event_count(ShipAudio.EVENT_STAB_OFF)
	Input.action_press("toggle_stabilization")
	var switched_on := await _until(
		func() -> bool: return _ship.stabilization.enabled, 60)
	Input.action_release("toggle_stabilization")
	await _tick()
	_ok("the stabilization key turns the system on", switched_on,
		str(_ship.stabilization.enabled))
	_ok("and raises its own quiet signal once",
		_audio.event_count(ShipAudio.EVENT_STAB_ON) == on_before + 1,
		"%d -> %d" % [on_before, _audio.event_count(ShipAudio.EVENT_STAB_ON)])
	# A second press must not be read as a repeat while the first is still held.
	Input.action_press("toggle_stabilization")
	var switched_off := await _until(
		func() -> bool: return not _ship.stabilization.enabled, 60)
	Input.action_release("toggle_stabilization")
	await _tick()
	_ok("and turns it off again", switched_off, str(_ship.stabilization.enabled))
	_ok("with a different signal for the other direction",
		_audio.event_count(ShipAudio.EVENT_STAB_OFF) == off_before + 1,
		"%d -> %d" % [off_before, _audio.event_count(ShipAudio.EVENT_STAB_OFF)])

	await _park()
	var emergency_before := _audio.event_count(ShipAudio.EVENT_EMERGENCY)
	_ship.linear_velocity = Vector2(700.0, 0.0)
	Input.action_press("emergency_brake")
	var engaged := await _until(
		func() -> bool: return _ship.emergency_brake.engaged, 60)
	_ok("Space engages the emergency brake", engaged,
		"engaged %s at %.0f px/s" % [str(_ship.emergency_brake.engaged), _ship.speed()])
	var retro_hot := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_RETRO) > 0.7, 120)
	_ok("the retro layer is the one that sounds", retro_hot,
		"level %.2f at brake power %.2f" % [_audio.level(ShipAudio.LAYER_RETRO),
			_plant.brake_power])
	_ok("emergency_on fired once", _audio.event_count(ShipAudio.EVENT_EMERGENCY)
		== emergency_before + 1, "%d -> %d" % [emergency_before,
			_audio.event_count(ShipAudio.EVENT_EMERGENCY)])
	await _wait(20)
	_ok("holding Space does not repeat the activation signal",
		_audio.event_count(ShipAudio.EVENT_EMERGENCY) == emergency_before + 1,
		"%d" % _audio.event_count(ShipAudio.EVENT_EMERGENCY))
	_release_all()
	await _until(func() -> bool: return _audio.level(ShipAudio.LAYER_RETRO) < 0.02, 300)


# --------------------------------------------------------------- 5. collisions --

func _contact(category: String, closing: float) -> Dictionary:
	return {
		"category": category,
		"closing_speed": closing,
		"kind": WorldObjects.KIND_ASTEROID,
		"description": {"title": "asteroid_test"},
		"object_valid": true,
	}


func _test_collisions() -> void:
	_beat("contact is classified and rate-limited")
	await _park()
	var heavy_before := _audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY)
	var medium_before := _audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM)
	var light_before := _audio.event_count(ShipAudio.EVENT_IMPACT_LIGHT)

	# The ship's own signal is the wiring: emitting it is exactly what the physics
	# does on a real contact, without needing a rock to be in the way.
	_ship.emit_signal("ship_collision_detected", _contact("HEAVY", 700.0))
	await _tick()
	_ok("a HEAVY contact raises the heavy sample",
		_audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY) == heavy_before + 1,
		"%d" % _audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY))
	# Two more bodies in the same frame: the global gate must drop them.
	_ship.emit_signal("ship_collision_detected", _contact("MEDIUM", 160.0))
	_ship.emit_signal("ship_collision_detected", _contact("LIGHT", 50.0))
	await _tick()
	_ok("contacts inside the same interval are dropped, not stacked",
		_audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM) == medium_before
		and _audio.event_count(ShipAudio.EVENT_IMPACT_LIGHT) == light_before,
		"medium %d, light %d" % [_audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM),
			_audio.event_count(ShipAudio.EVENT_IMPACT_LIGHT)])
	await _wait(12)
	_ship.emit_signal("ship_collision_detected", _contact("MEDIUM", 160.0))
	await _tick()
	_ok("a MEDIUM contact after the interval raises the medium sample",
		_audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM) == medium_before + 1,
		"%d" % _audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM))
	await _wait(12)
	_ship.emit_signal("ship_collision_detected", _contact("LIGHT", 50.0))
	await _tick()
	_ok("a LIGHT contact raises the light sample",
		_audio.event_count(ShipAudio.EVENT_IMPACT_LIGHT) == light_before + 1,
		"%d" % _audio.event_count(ShipAudio.EVENT_IMPACT_LIGHT))
	_ok("the three weights are three different events",
		_played.has(ShipAudio.EVENT_IMPACT_HEAVY)
		and _played.has(ShipAudio.EVENT_IMPACT_MEDIUM)
		and _played.has(ShipAudio.EVENT_IMPACT_LIGHT), str(_played))

	# Then the real thing: fly into a rock and let the physics raise the signal.
	await _park()
	_stone_ahead()
	var real_before := _counts()
	var rammed := await _ram_stone(_ship.max_forward_speed * 0.85)
	_ok("flying into a rock raises exactly one impact",
		rammed and _counts() == real_before + 1,
		"%d new event(s) at %.0f px/s" % [_counts() - real_before, _ship.speed()])
	_ok("the report names the band it was raised in",
		_audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY) > heavy_before
		or _audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM) > medium_before,
		"heavy %d, medium %d" % [_audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY),
			_audio.event_count(ShipAudio.EVENT_IMPACT_MEDIUM)])


# ---------------------------------------------------- 6. control and the switch --

func _test_control_and_switch() -> void:
	_beat("control cuts and the master switch")
	await _park()
	var off_before := _audio.event_count(ShipAudio.EVENT_CONTROL_OFF)
	var on_before := _audio.event_count(ShipAudio.EVENT_CONTROL_ON)
	_ship.disable_control()
	await _tick()
	_ok("cutting control raises its signal",
		_audio.event_count(ShipAudio.EVENT_CONTROL_OFF) == off_before + 1,
		"%d -> %d" % [off_before,
			_audio.event_count(ShipAudio.EVENT_CONTROL_OFF)])
	_ship.enable_control()
	await _tick()
	_ok("restoring it raises the other",
		_audio.event_count(ShipAudio.EVENT_CONTROL_ON) == on_before + 1,
		"%d -> %d" % [on_before, _audio.event_count(ShipAudio.EVENT_CONTROL_ON)])

	_audio.enabled = false
	Input.action_press("thrust_forward")
	await _wait(30)
	_ok("a switched-off mixer keeps every layer silent",
		_audio.level(ShipAudio.LAYER_MAIN) < 0.001,
		"%.4f with the plant at %.2f" % [_audio.level(ShipAudio.LAYER_MAIN),
			_plant.main_power])
	var events_before := _counts()
	_ship.emit_signal("ship_collision_detected", _contact("HEAVY", 700.0))
	await _tick()
	_ok("and refuses events while it is off", _counts() == events_before,
		"%d new" % (_counts() - events_before))
	_audio.enabled = true
	var back := await _until(
		func() -> bool: return _audio.level(ShipAudio.LAYER_MAIN) > 0.5, 240)
	_ok("switching it back on lets the hum follow the burn again", back,
		"%.2f" % _audio.level(ShipAudio.LAYER_MAIN))
	_release_all()
	await _park()


# ------------------------------------------------------------ 7. the debug hud --

func _test_panel_and_toggle() -> void:
	_beat("the debug overlay: F3, the required lines and the old indices")
	_release_all()
	_ship.show_debug = false
	await _tick()
	_ok("the overlay starts down", not _debug.visible, str(_debug.visible))
	Input.action_press("toggle_debug")
	await _tick()
	Input.action_release("toggle_debug")
	await _tick()
	_ok("F3 raises it", _ship.show_debug and _debug.visible,
		"show=%s visible=%s" % [str(_ship.show_debug), str(_debug.visible)])
	Input.action_press("toggle_debug")
	await _tick()
	Input.action_release("toggle_debug")
	await _tick()
	_ok("and F3 puts it back down", not _ship.show_debug and not _debug.visible,
		"show=%s visible=%s" % [str(_ship.show_debug), str(_debug.visible)])

	_ship.show_debug = true
	await _tick()
	var lines := _debug.readout()
	var text := "\n".join(lines)
	var missing := ""
	for token in ["speed", "velocity", "yaw", "nose", "active", "state", "control",
			"external", "last hit", "stab", "e-brake", "boost", "charge", "audio",
			"levels", "fps", "phys", "hull"]:
		if not text.contains(token):
			missing += token + " "
	_ok("the panel carries every row the stage asks for", missing == "",
		"missing: " + missing + " (%d rows)" % lines.size())
	_ok("the audio line reports the inventory honestly",
		text.contains("strm") and text.contains("voices"), lines[lines.size() - 4])
	_ok("the panel's first ten rows are still the flight block",
		lines.size() > 9 and lines[0].begins_with("mode")
		and lines[1].begins_with("speed") and lines[7].begins_with("yaw"),
		"%s | %s" % [lines[0], lines[7]])
	_ship.show_debug = false
	await _tick()


# ------------------------------------------------------------- 8. endurance --

func _test_endurance() -> void:
	_beat("endurance: a thousand frames of everything switching")
	await _park()
	_clear_arena()
	var audio_children := _audio.get_child_count()
	var ship_children := _ship.get_child_count()
	var non_finite := 0
	var out_of_range := 0
	for i in 1000:
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
		if i % 300 < 20:
			keys.append("thrust_backward")
		for action in ["thrust_forward", "thrust_backward", "strafe_left",
				"strafe_right", "turn_left", "turn_right", "emergency_brake", "boost"]:
			if keys.has(action):
				Input.action_press(action)
			else:
				Input.action_release(action)
		if i % 250 == 0:
			_ship.stabilization.toggle()
		if i % 400 == 0:
			# The master switch is part of the surface, so it is hammered too.
			_audio.enabled = not _audio.enabled
		await _step()
		if not is_finite(_ship.linear_velocity.x) or not is_finite(_ship.speed()) \
				or not is_finite(_ship.angular_velocity):
			non_finite += 1
		for layer in ShipAudio.layer_names():
			var current := _audio.level(layer)
			if current < -0.001 or current > ShipAudio.MAX_LAYER_LEVEL + 0.001:
				out_of_range += 1
	_release_all()
	_audio.enabled = true
	_ship.stabilization.set_enabled(false)
	_ok("endurance: a thousand frames stayed finite and every level in range",
		non_finite == 0 and out_of_range == 0,
		"%d non-finite, %d out-of-range" % [non_finite, out_of_range])
	_ok("endurance: not one player and not one node was created",
		_audio.get_child_count() == audio_children
		and _ship.get_child_count() == ship_children,
		"%d audio children, %d hull children" % [_audio.get_child_count(),
			_ship.get_child_count()])
	await _wait(60)
	_ok("endurance: it all comes back to rest",
		_plant.total_load() < 0.001 and _audio.level(ShipAudio.LAYER_MAIN) < 0.02,
		"load %.4f, main level %.3f" % [_plant.total_load(),
			_audio.level(ShipAudio.LAYER_MAIN)])


# ---------------------------------------------------------------- 9. relaunch --

func _test_relaunch() -> void:
	_beat("relaunch: a fresh hull starts with a fresh mixer")
	_ship.add_external_acceleration("test_leftover", Vector2(60.0, 0.0))
	await _step()
	var second := (load(MAP) as PackedScene).instantiate()
	root.add_child(second)
	await process_frame
	await physics_frame
	var fresh := second.get_node("Ship") as ShipController
	var fresh_audio := fresh.get_node_or_null("Audio") as ShipAudio
	_ok("a fresh hull brings its own mixer",
		fresh_audio != null and fresh_audio != _audio, str(fresh_audio))
	if fresh_audio != null:
		_ok("with no event and no level carried over",
			fresh_audio.event_count(ShipAudio.EVENT_BOOST_ON) == 0
			and fresh_audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY) == 0
			and fresh_audio.level(ShipAudio.LAYER_MAIN) == 0.0,
			"boost %d, hits %d, main %.2f" % [
				fresh_audio.event_count(ShipAudio.EVENT_BOOST_ON),
				fresh_audio.event_count(ShipAudio.EVENT_IMPACT_HEAVY),
				fresh_audio.level(ShipAudio.LAYER_MAIN)])
		_ok("and its overlay is down", not fresh.show_debug, str(fresh.show_debug))
	second.queue_free()
	await process_frame
	await physics_frame
	_ok("freeing the second hull does not disturb the first",
		is_instance_valid(_ship) and is_instance_valid(_audio)
		and not is_instance_valid(fresh_audio), "first hull still alive")
	_ship.clear_external_accelerations()


# ---------------------------------------------------------------- 10. balance --

func _test_balance() -> void:
	_beat("balance: measured against the exported numbers")
	await _balance_forward_and_coast()
	await _balance_turn_and_strafe()
	await _balance_brakes()
	await _balance_boost_and_stabilizer()
	_ok("the envelope is still the one the earlier stages pinned",
		_ship.braking_acceleration > _ship.forward_acceleration
		and _ship.reverse_acceleration < _ship.forward_acceleration
		and _ship.max_reverse_speed < _ship.max_forward_speed
		and _ship.settings().maneuvering_engine_power < _ship.forward_acceleration * 0.6
		and _ship.settings().max_lateral_speed < _ship.max_forward_speed * 0.5,
		"fwd %.0f, brake %.0f, reverse %.0f/%.0f, strafe %.0f/%.0f" % [
			_ship.forward_acceleration, _ship.braking_acceleration,
			_ship.reverse_acceleration, _ship.max_reverse_speed,
			_ship.settings().maneuvering_engine_power,
			_ship.settings().max_lateral_speed])


func _balance_forward_and_coast() -> void:
	await _park()
	var max_v := _ship.max_forward_speed
	Input.action_press("thrust_forward")
	var start := Engine.get_physics_frames()
	var reached := await _until(
		func() -> bool: return _ship.forward_speed() >= max_v * 0.99, 900)
	var seconds := float(Engine.get_physics_frames() - start) / 60.0
	print("  measured 0 -> %.0f px/s: %.2f s" % [max_v, seconds])
	_ok("the hull takes a human-scale moment to reach cruise",
		reached and seconds >= 1.5 and seconds <= 3.5, "%.2f s" % seconds)
	_ok("and it stops exactly at the exported ceiling",
		absf(_ship.forward_speed() - max_v) < max_v * 0.02,
		"%.0f of %.0f px/s" % [_ship.forward_speed(), max_v])

	Input.action_release("thrust_forward")
	var ramped_down := await _until(
		func() -> bool: return _plant.main_power < 0.01, 180)
	var v0 := _ship.speed()
	start = Engine.get_physics_frames()
	var halved := await _until(
		func() -> bool: return _ship.speed() <= v0 * 0.5, 900)
	var half := float(Engine.get_physics_frames() - start) / 60.0
	var promised := log(2.0) / maxf(_ship.linear_drag, 0.001)
	print("  measured coast half-life: %.2f s (linear_drag %.2f promises %.2f)" % [
		half, _ship.linear_drag, promised])
	_ok("a released engine coasts for seconds, it does not stop",
		ramped_down and halved and half > 2.5, "%.2f s half-life" % half)
	_ok("and the glide follows the exponential the drag promises",
		halved and absf(half - promised) <= 0.9,
		"%.2f s against %.2f s" % [half, promised])

	await _park()
	Input.action_press("thrust_backward")
	var reversed := await _until(
		func() -> bool: return _ship.forward_speed() <= -_ship.max_reverse_speed * 0.95, 600)
	print("  measured astern ceiling: %.0f of %.0f px/s" % [
		-_ship.forward_speed(), _ship.max_reverse_speed])
	_ok("astern reaches its own, lower ceiling", reversed,
		"%.0f px/s" % _ship.forward_speed())
	_ok("reverse is deliberately the weaker direction",
		_ship.max_reverse_speed < max_v * 0.5,
		"%.0f of %.0f px/s" % [_ship.max_reverse_speed, max_v])
	_release_all()
	await _park()


func _balance_turn_and_strafe() -> void:
	await _park()
	var top_spin := _ship.max_angular_speed
	Input.action_press("turn_left")
	var start := Engine.get_physics_frames()
	var spun := await _until(
		func() -> bool: return absf(_ship.angular_velocity) >= top_spin * 0.99, 180)
	var seconds := float(Engine.get_physics_frames() - start) / 60.0
	print("  measured 0 -> %.2f rad/s: %.2f s" % [top_spin, seconds])
	_ok("the rudder reaches its full rate quickly but not instantly",
		spun and seconds >= 0.12 and seconds <= 0.6, "%.2f s" % seconds)
	var at_release := absf(_ship.angular_velocity)
	_release_all()
	var release_clock := Time.get_ticks_usec()
	await _wait(4)
	# The spin must coast down, not be cut on the frame the lever is released.
	# Measured against the flight model's own deceleration over the time that
	# really elapsed, rather than against a bare fraction of the release value:
	# a physics tick is longer than 1/60 s on a loaded machine, and "75% of the
	# release still turning four frames later" is a 60 Hz assumption that fails a
	# ship which is behaving exactly as designed. A cut spin drops to ~0 and
	# fails this either way.
	var elapsed := float(Time.get_ticks_usec() - release_clock) / 1000000.0
	var after := absf(_ship.angular_velocity)
	var lost := at_release - after
	var decelerable := _ship.angular_deceleration * elapsed
	_ok("letting go does not cut the spin",
		after > at_release * 0.3 and lost <= decelerable * 2.0 + 0.05,
		"%.2f of %.2f rad/s, lost %.2f over %.3f s (deceleration %.2f rad/s^2 allows %.2f)" % [
			after, at_release, lost, elapsed, _ship.angular_deceleration, decelerable])
	start = Engine.get_physics_frames()
	var stopped := await _until(
		func() -> bool: return absf(_ship.angular_velocity) < top_spin * 0.05, 600)
	var glide := float(Engine.get_physics_frames() - start) / 60.0
	var promised := top_spin / maxf(_ship.angular_deceleration, 0.001)
	print("  measured spin-down: %.2f s (angular_deceleration %.2f promises %.2f)" % [
		glide, _ship.angular_deceleration, promised])
	_ok("the spin bleeds off over about the promised time",
		stopped and glide >= promised * 0.7 and glide <= promised * 1.9,
		"%.2f s against %.2f s" % [glide, promised])
	await _park()

	# The rudder must not weaken with speed: a survey hull that cannot turn at
	# cruise is a hull that cannot avoid anything.
	_ship.linear_velocity = Vector2(_ship.max_forward_speed, 0.0)
	Input.action_press("turn_left")
	var spun_fast := await _until(
		func() -> bool: return absf(_ship.angular_velocity) >= top_spin * 0.99, 180)
	_ok("the rudder is just as strong at cruise", spun_fast,
		"%.2f rad/s at %.0f px/s" % [absf(_ship.angular_velocity), _ship.speed()])
	_release_all()
	await _park()

	var max_lateral := _ship.settings().max_lateral_speed
	# Explicitly settle the heading first: the previous segment ended mid-spin, and
	# this check is about strafe, not about whatever rotation was left over.
	_place(CORRIDOR, 0.0)
	_ship.angular_velocity = 0.0
	await _tick()
	var heading_before := _ship.rotation
	Input.action_press("strafe_right")
	var strafed := await _until(
		func() -> bool: return _ship.drift_speed() >= max_lateral * 0.95, 600)
	print("  measured sideways ceiling: %.0f of %.0f px/s" % [
		_ship.drift_speed(), max_lateral])
	_ok("the strafe pair reaches its own ceiling", strafed,
		"%.0f px/s" % _ship.drift_speed())
	_ok("strafing does not add forward speed",
		absf(_ship.forward_speed()) < 5.0, "%.1f px/s along the nose" % _ship.forward_speed())
	_ok("strafing does not spin the hull", absf(_ship.angular_velocity) < 0.001,
		"%.4f rad/s" % _ship.angular_velocity)
	_ok("and the nose keeps pointing where it was",
		absf(wrapf(_ship.rotation - heading_before, -PI, PI)) < 0.02,
		"%.4f rad from %.4f" % [_ship.rotation, heading_before])
	Input.action_release("strafe_right")
	await _wait(5)
	_ok("releasing E keeps the sideways speed it earned",
		_ship.drift_speed() > max_lateral * 0.85,
		"%.0f of %.0f px/s five frames after release" % [
			_ship.drift_speed(), max_lateral])
	_release_all()
	await _park()


func _balance_brakes() -> void:
	await _park()
	var max_v := _ship.max_forward_speed
	var stop_at := _ship.velocity_stop_threshold

	# The emergency lever: full retro against the real velocity, and it must never
	# spend the last of the speed by accelerating the other way.
	#
	# The signed speed is read along the flight path, not along the nose. The retro
	# burn is aimed at the real velocity, so the hull stops either way - but the
	# hull's nose is not obliged to point along it, and a nose-ward projection of a
	# sideways flight reads negative from the very first frame. That would call a
	# hull "thrown backwards" before the brake had done anything at all.
	var flight := Vector2.RIGHT
	_ship.linear_velocity = flight * max_v
	Input.action_press("emergency_brake")
	var start := Engine.get_physics_frames()
	var e_time := 0.0
	var flipped := false
	for i in 400:
		await _step()
		if _ship.speed() <= stop_at:
			e_time = float(Engine.get_physics_frames() - start) / 60.0
			break
		if _ship.linear_velocity.dot(flight) < -20.0:
			flipped = true
			break
	Input.action_release("emergency_brake")
	print("  measured emergency stop from %.0f px/s: %.2f s" % [max_v, e_time])
	_ok("the emergency brake stops a cruise hull inside a second",
		e_time > 0.0 and e_time < 1.2 and _ship.speed() <= stop_at, "%.2f s" % e_time)
	_ok("and never throws the hull backwards", not flipped,
		"%.0f px/s along the flight path" % _ship.linear_velocity.dot(flight))
	await _park()

	# The pilot's own S, for comparison.
	_ship.linear_velocity = Vector2(max_v, 0.0)
	Input.action_press("thrust_backward")
	start = Engine.get_physics_frames()
	var s_time := 0.0
	for i in 500:
		await _step()
		if _ship.speed() <= stop_at:
			s_time = float(Engine.get_physics_frames() - start) / 60.0
			break
	_release_all()
	print("  measured ordinary stop from %.0f px/s: %.2f s" % [max_v, s_time])
	_ok("the pilot's brake is a controlled burn, and slower",
		s_time > 0.0 and s_time > e_time * 1.1,
		"%.2f s against %.2f s" % [s_time, e_time])
	_ok("so the emergency lever is a real step up",
		e_time < s_time * 0.85, "%.2f s is %.0f%% of %.2f s" % [e_time,
			100.0 * e_time / maxf(s_time, 0.001), s_time])
	await _park()


func _balance_boost_and_stabilizer() -> void:
	await _park()
	var max_v := _ship.max_forward_speed
	var factor := _ship.assists.boost_max_speed_multiplier
	_ship.boost.set_charge(1.0)
	Input.action_press("thrust_forward")
	Input.action_press("boost")
	var peak := 0.0
	var frames := 0
	while frames < 600 and _ship.boost.boost_charge > 0.001:
		await _step()
		frames += 1
		peak = maxf(peak, _ship.forward_speed())
	print("  measured boosted peak: %.0f of %.0f px/s over %.2f s of tank" % [
		peak, max_v * factor, float(frames) / 60.0])
	_ok("boost lifts the ceiling by at least a fifth", peak >= max_v * 1.2,
		"%.0f px/s, %.2f of cruise" % [peak, peak / max_v])
	_ok("and not beyond it", peak <= max_v * factor * 1.05,
		"%.2f of x%.2f" % [peak / max_v, factor])
	_release_all()
	await _park()
	# The tank spent part of itself; this phase measured the shove, not the economy.
	_ship.boost.set_charge(1.0)

	# The stabilizer: kill a broadside drift, and hand the lever back the moment the
	# pilot asks for it.
	await _park()
	_ship.stabilization.set_enabled(true)
	await _wait(30)
	_ship.linear_velocity = Vector2(0.0, 350.0)
	var opening := absf(_ship.drift_speed())
	var start := Engine.get_physics_frames()
	var killed := await _until(
		func() -> bool: return absf(_ship.drift_speed()) < 30.0, 400)
	var seconds := float(Engine.get_physics_frames() - start) / 60.0
	print("  measured stabilizer drift %.0f -> %.0f px/s in %.2f s" % [
		opening, absf(_ship.drift_speed()), seconds])
	_ok("the stabilizer takes a broadside drift out", killed,
		"%.0f -> %.0f px/s" % [opening, absf(_ship.drift_speed())])
	_ok("without reversing it", _ship.linear_velocity.y > -25.0,
		"%.1f px/s sideways" % _ship.linear_velocity.y)
	_ok("and it does it in seconds, not in one frame", seconds > 0.3,
		"%.2f s" % seconds)
	Input.action_press("strafe_right")
	var pilot := await _until(
		func() -> bool: return _ship.drift_speed() > 80.0, 300)
	_ok("the pilot still outranks the assist", pilot,
		"%.0f px/s with E held" % _ship.drift_speed())
	_release_all()
	_ship.stabilization.set_enabled(false)
	await _park()