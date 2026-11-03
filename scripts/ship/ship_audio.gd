extends Node
class_name ShipAudio

## The ship's ears, and the only file that decides how loud anything on the hull is.
##
## Sub-stage 1.5 asks for sound that follows the physics rather than announcing it.
## The whole file is built around one rule: **a layer's level is a power the engine
## plant already computed**, never a number derived from a key. `EngineController`
## says how hard each group is burning; `ShipAudio` turns that into a level; the
## jets in `engine_visuals.gd` read the same plant. So a thruster at 20% is 20% of
## its flame, 20% of its hum and 20% of its acceleration, and there is only one
## place the three could ever disagree (spec 10).
##
## Two kinds of sound, and they are managed differently on purpose:
##
## - **Continuous layers**, one `AudioStreamPlayer` each, created once in `_ready()`
##   and never replaced: main engine, retro plant (brake + astern + the emergency
##   brake), the strafing pair, the yaw verniers, and the boost component. Their
##   levels are ramped with `move_toward`, their pitch settles exponentially, and a
##   layer is stopped only after its level has reached zero - so a released W fades,
##   it does not click.
## - **One-shot events**, played through a fixed pool of eight voices: three
##   collision weights and the short system signals. A voice is taken only if it is
##   idle, so an event is skipped rather than cutting the tail off another; and every
##   event has a minimum interval, so a hull grinding along a rock cannot turn the
##   mixer into a machine gun.
##
## The stabilizer deliberately has no loop of its own. It borrows the retro,
## manoeuvring and rotation groups (sub-stage 1.3), which means its corrections are
## already the four thruster layers at the power the plant reports. Adding a fifth
## "stabilizing" hum would duplicate exactly what the spec says not to duplicate; what
## the pilot hears instead is the on/off signal plus the jets that are actually
## firing. `stabilizer_bed` exists only so a designer can add a quiet electronics
## texture later without touching this file.
##
## **Missing audio is a normal state, not a failure.** Every stream is resolved by
## name from `res://assets/audio/ship/`, trying `.ogg`, `.wav` and `.mp3`. A name
## with no file on disk resolves to `null`, the player stays silent, and the event is
## still counted and rate-limited - so the wiring can be tested before the audio
## exists, and dropping a correctly named file in is the whole of "installing" it.
## `missing_streams()` and `report()` say what is still absent; the project never
## generates a placeholder file to make a check pass.

## Emitted when a one-shot event is committed (accepted by the rate limit), with its
## name and the decibels it was played at. The volume is `-INF` when the stream is
## missing, which is the honest reading of "played nothing".
signal sound_event(event_name: String, volume_db: float)

# --- continuous layers -------------------------------------------------------
const LAYER_MAIN := "engine_main"
const LAYER_RETRO := "engine_retro"
const LAYER_STRAFE := "engine_strafe"
const LAYER_ROTATION := "engine_rotation"
const LAYER_BOOST := "boost_layer"
## A quiet bed for the stabilizer's own electronics. There is no file for it and the
## system does not need one; it exists so a sound designer can add
## `stabilizer_bed.*` without touching this file, and it is mixed *under* the
## thruster layers rather than instead of them.
const LAYER_STABILIZER := "stabilizer_bed"

# --- one-shot events ---------------------------------------------------------
const EVENT_IMPACT_LIGHT := "impact_light"
const EVENT_IMPACT_MEDIUM := "impact_medium"
const EVENT_IMPACT_HEAVY := "impact_heavy"
const EVENT_STAB_ON := "stabilizer_on"
const EVENT_STAB_OFF := "stabilizer_off"
const EVENT_BOOST_ON := "boost_on"
const EVENT_BOOST_LOW := "boost_low"
const EVENT_BOOST_EMPTY := "boost_empty"
const EVENT_BOOST_READY := "boost_ready"
const EVENT_CONTROL_ON := "control_on"
const EVENT_CONTROL_OFF := "control_off"
const EVENT_EMERGENCY := "emergency_on"
const EVENT_POWER_ON := "power_on"

## Where a designer drops the files. The base name is the constant above; the
## extension is whatever the import produced.
const SOUND_DIR := "res://assets/audio/ship/"
const SOUND_EXTENSIONS := [".ogg", ".wav", ".mp3"]

## Level below which a layer is treated as silent and its player is stopped. Small
## enough to be inaudible, large enough that the ramp reaches it exactly instead of
## asymptotically.
const AUDIBLE_FLOOR := 0.004
## What a stopped player's volume is set to, so an old value cannot leak into the
## frame the next `play()` happens on.
const SILENCE_DB := -80.0
## The highest a layer's smoothed level may be: 1.0 of authority, plus headroom for
## the main engine's over-authorisation under boost (x1.8 at the shipped tuning).
const MAX_LAYER_LEVEL := 1.5

## Voices in the one-shot pool. Eight is more than the ship can legitimately raise in
## one interval, with room for a system signal alongside. Fixed on purpose: creating
## players per event is the one thing the spec names as forbidden.
const VOICE_COUNT := 8
## The dictionary key of the global impact limiter, kept apart from the event names.
const _IMPACT_GATE := "@impact"

## The tuning. Unset, defaults are used, so a hull built in code still has a mixer.
@export var parameters: ShipAudioParameters

## The master switch for the hull's sound. Off stops the layers and refuses events;
## the flight model never sees it, which is what lets a test fly a silent ship.
@export var enabled := true

## An inspector override: `{ "engine_main": AudioStream, ... }`. Anything set here
## wins over the file lookup, which is how a scene can re-use one stream under
## another name, or a test can supply a stream without writing a file.
@export var streams: Dictionary = {}

var _loops := {}
var _voices: Array[AudioStreamPlayer] = []
var _voice_cursor := 0
## Smoothed level per layer, 0..MAX_LAYER_LEVEL.
var _levels := {}
## Smoothed pitch per layer.
var _pitches := {}

## When each event was last committed, in physics seconds.
var _last_played := {}
## How many times each event's *intent* was accepted. Counted even when the stream is
## missing, so the wiring is observable without audio files.
var _counts := {}
## Resolved streams, including the nulls, so a missing file costs one `exists()`.
var _stream_cache := {}

var _ship: ShipController
var _plant: EngineController

# Edge state for the signals that are transitions rather than powers.
var _stabilizer_was := false
var _emergency_was := false
var _boost_was := false
var _charge_was := 1.0
var _low_armed := true
## Set while the tank is dry, cleared when it has recovered enough to light again.
## The "ready" blip fires on that clearing, not on the charge crossing a level on some
## arbitrary later frame - which is the difference between an announcement and silence.
var _empty_latched := false
var _booted := false


func _ready() -> void:
	_build_players()
	# The parent is a `ShipController` in the shipping scene. In a legacy or hand-built
	# hull there may be none, and that is fine: the component simply stays silent.
	var parent := get_parent()
	if parent is ShipController:
		_ship = parent as ShipController
		# The transitions that are events rather than levels. Connected here rather
		# than polled, because these are exactly the signals 1.4 exists to provide; a
		# listener that polled `movement_enabled` instead would be able to miss a
		# cut-scene's single-frame switch.
		_ship.ship_collision_detected.connect(_on_collision)
		_ship.ship_control_enabled.connect(_on_control_enabled)
		_ship.ship_control_disabled.connect(_on_control_disabled)


func _process(delta: float) -> void:
	if not enabled:
		_hush()
		return
	_resolve()
	if _ship == null:
		return
	var p := settings()
	_step_layers(p, delta)
	_step_signals(p)
	if not _booted:
		_booted = true
		if p.play_boot_signal:
			_play_event(EVENT_POWER_ON)


## The layer and event names, in the order `report()` treats them. Read by the panel
## and by anything that wants to enumerate the mixer without knowing its shape.
static func layer_names() -> Array[String]:
	var out: Array[String] = [LAYER_MAIN, LAYER_RETRO, LAYER_STRAFE, LAYER_ROTATION,
		LAYER_BOOST, LAYER_STABILIZER]
	return out


static func event_names() -> Array[String]:
	var out: Array[String] = [EVENT_IMPACT_LIGHT, EVENT_IMPACT_MEDIUM, EVENT_IMPACT_HEAVY,
		EVENT_STAB_ON, EVENT_STAB_OFF, EVENT_BOOST_ON, EVENT_BOOST_LOW,
		EVENT_BOOST_EMPTY, EVENT_BOOST_READY, EVENT_CONTROL_ON, EVENT_CONTROL_OFF,
		EVENT_EMERGENCY, EVENT_POWER_ON]
	return out


## The live level of one layer, 0..MAX_LAYER_LEVEL. The panel prints it and a test
## reads it; the mixer itself never needs it back.
func level(layer: String) -> float:
	return float(_levels.get(layer, 0.0))


## The decibels a layer's player is currently set to. `SILENCE_DB` when stopped.
func layer_volume_db(layer: String) -> float:
	var player: AudioStreamPlayer = _loops.get(layer)
	return player.volume_db if player != null else SILENCE_DB


## How many times an event's intent was accepted by the rate limiter, whether or not
## a file existed for it.
func event_count(event_name: String) -> int:
	return int(_counts.get(event_name, 0))


## How many streams resolved to a real `AudioStream`. Zero is a perfectly valid
## answer for this project today; `missing_streams()` is the list to fill.
func loaded_streams() -> int:
	var count := 0
	for name in _all_names():
		if _stream_for(name) != null:
			count += 1
	return count


func total_streams() -> int:
	return _all_names().size()


func missing_streams() -> Array[String]:
	var out: Array[String] = []
	for name in _all_names():
		if _stream_for(name) == null:
			out.append(name)
	return out


## The panel's view of the mixer: one line for the switch and the inventory, one for
## the live levels. Kept short because the debug overlay is already long.
func report() -> Array[String]:
	# Short on purpose: these are the last rows of a 35-row panel and land in its
	# rightmost column, where the screen has about forty characters left. Full words
	# there would push the text off the right edge of a 960 px frame.
	var out: Array[String] = [
		"audio     %s %d/%d strm %d voices" % [
			"ON" if enabled else "OFF", loaded_streams(), total_streams(),
			_voices.size()],
		"levels    m%.2f r%.2f s%.2f t%.2f b%.2f" % [
			level(LAYER_MAIN), level(LAYER_RETRO), level(LAYER_STRAFE),
			level(LAYER_ROTATION), level(LAYER_BOOST)],
	]
	return out


## One layer's player, for a caller that needs to check playing state. Null when the
## layer does not exist.
func layer_player(layer: String) -> AudioStreamPlayer:
	return _loops.get(layer) as AudioStreamPlayer


func settings() -> ShipAudioParameters:
	if parameters == null:
		parameters = ShipAudioParameters.new()
	return parameters


# ------------------------------------------------------------- 1. plumbing -----

## Create every player once. Nothing below this point ever adds or removes a node,
## which is what keeps a ship that flies for an hour from leaking a voice per hit.
func _build_players() -> void:
	for layer in layer_names():
		var player := AudioStreamPlayer.new()
		player.name = "Layer_" + layer
		player.bus = _bus_for_layer()
		var stream := _stream_for(layer)
		player.stream = stream
		_configure_loop(stream)
		add_child(player)
		_loops[layer] = player
		_levels[layer] = 0.0
		_pitches[layer] = 1.0
	for i in VOICE_COUNT:
		var voice := AudioStreamPlayer.new()
		voice.name = "Voice_%02d" % i
		# The bus is set per event; the default is the systems bus so a voice that
		# somehow gets played without one is still on the right subtree.
		voice.bus = AudioMixer.SHIP_SYSTEMS
		add_child(voice)
		_voices.append(voice)


## Every continuous layer is a thruster texture, so it belongs on the engines bus. A
## project without the layout folds to Master rather than failing a `play()` on a bus
## that is not there.
func _bus_for_layer() -> StringName:
	return AudioMixer.SHIP_ENGINES if AudioMixer.has_bus(AudioMixer.SHIP_ENGINES) \
		else AudioMixer.MASTER


func _resolve() -> void:
	if _ship == null:
		var parent := get_parent()
		if parent is ShipController:
			_ship = parent as ShipController
	if _ship != null and _plant == null:
		# The parent's own `@onready` resolves after this child's `_ready`, so the
		# plant is looked up on the first frame rather than in `_ready`.
		_plant = _ship.engines


## A stream by name: the inspector override first, then the files on disk. The
## answer - including "nothing" - is cached, so a missing file is asked about once.
func _stream_for(stream_name: String) -> AudioStream:
	if _stream_cache.has(stream_name):
		return _stream_cache[stream_name] as AudioStream
	var found: AudioStream = null
	var given = streams.get(stream_name)
	if given is AudioStream:
		found = given as AudioStream
	else:
		for extension in SOUND_EXTENSIONS:
			var path := SOUND_DIR + stream_name + String(extension)
			if ResourceLoader.exists(path):
				var loaded := load(path)
				if loaded is AudioStream:
					found = loaded as AudioStream
					break
	_stream_cache[stream_name] = found
	return found


## Make a stream loop for the layers, whatever format the designer shipped it in.
## An `AudioStreamWAV` has to have its loop end named in frames; the imported OGG
## and MP3 streams only need their flag. Anything else is left as imported.
func _configure_loop(stream: AudioStream) -> void:
	if stream == null:
		return
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = maxi(int(wav.get_length() * wav.mix_rate), 1)
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true


func _all_names() -> Array[String]:
	var out: Array[String] = []
	out.append_array(layer_names())
	out.append_array(event_names())
	return out


# -------------------------------------------------------------- 2. layers ------

## Read the plant's powers and turn them into levels. This is the only place a sound
## number is derived from a physics number, and every branch reads the same object
## the jets read.
func _step_layers(p: ShipAudioParameters, delta: float) -> void:
	var main := 0.0
	var retro := 0.0
	var strafe := 0.0
	var rotation := 0.0
	if _plant != null:
		# `main_power` is allowed past 1.0 under boost - that is the plant's way of
		# saying "more than a main engine" - and the layer follows it, so the extra
		# authority is audible instead of being clipped flat.
		main = maxf(_plant.main_power, 0.0)
		retro = clampf(_plant.brake_power + _plant.astern_power, 0.0, 1.0)
		strafe = absf(_plant.strafe_power)
		rotation = absf(_plant.rotation_power)
	var boost := _boost_level()
	var stabilizer := 0.0
	if _ship.stabilization != null and _ship.stabilization.enabled:
		stabilizer = clampf(_ship.stabilization.authority, 0.0, 1.0)

	# The emergency brake is the same retro group at a harder deceleration, so it is
	# the same layer with a little more gain - not a second sound.
	var retro_db := p.retro_volume_db
	if _ship.emergency_brake != null and _ship.emergency_brake.engaged:
		retro_db += p.emergency_extra_db

	_step_layer(LAYER_MAIN, main, p.main_volume_db, p.engine_fade_time, delta)
	_step_layer(LAYER_RETRO, retro, retro_db, p.engine_fade_time, delta)
	_step_layer(LAYER_STRAFE, strafe, p.strafe_volume_db, p.rotation_fade_time, delta)
	_step_layer(LAYER_ROTATION, rotation, p.rotation_volume_db, p.rotation_fade_time, delta)
	_step_layer(LAYER_BOOST, boost, p.boost_volume_db, p.boost_fade_time, delta)
	# The bed is mixed well below the thruster layers; when there is no file it is
	# simply a level that never makes a sound.
	_step_layer(LAYER_STABILIZER, stabilizer * 0.35, p.system_volume_db,
		p.engine_fade_time, delta)

	# Pitch is seasoning: it follows the main level and is pulled up by the boost.
	var main_level := level(LAYER_MAIN)
	var want := lerpf(p.main_pitch_low, p.main_pitch_high, clampf(main_level, 0.0, 1.0))
	if boost > 0.0:
		want = lerpf(want, p.boost_pitch_high, boost)
	var sharp := _settle(float(_pitches.get(LAYER_MAIN, 1.0)), want, p.pitch_fade_time, delta)
	_pitches[LAYER_MAIN] = sharp
	_apply_pitch(LAYER_MAIN)


## How lit the boost is, 0..1: the authority factor above 1.0, normalised by the
## multiplier's own span. Read from the factor rather than `active`, because the
## factor is what ramps out after the lever is released, and the layer has to follow
## the ramp down instead of stopping on the frame the flag flipped.
func _boost_level() -> float:
	if _ship.boost == null:
		return 0.0
	var span := maxf(_ship.boost.settings().boost_multiplier - 1.0, 0.001)
	return clampf((_ship.boost.factor - 1.0) / span, 0.0, 1.0)


## One layer's frame: ramp the level, then let the player follow it. The player is
## started the first frame the level is audible and stopped only once the ramp has
## actually reached zero, which is what makes the fade a fade and not a cut.
func _step_layer(layer: String, target: float, base_db: float, fade: float,
		delta: float) -> void:
	var level_now := move_toward(level(layer),
		clampf(target, 0.0, MAX_LAYER_LEVEL), delta / maxf(fade, 0.001))
	_levels[layer] = level_now
	var player: AudioStreamPlayer = _loops.get(layer)
	if player == null or player.stream == null:
		return
	if level_now > AUDIBLE_FLOOR:
		if not player.playing:
			player.play()
		player.volume_db = base_db + linear_to_db(minf(level_now, MAX_LAYER_LEVEL))
	else:
		player.volume_db = SILENCE_DB
		if player.playing:
			player.stop()


func _apply_pitch(layer: String) -> void:
	var player: AudioStreamPlayer = _loops.get(layer)
	if player != null:
		player.pitch_scale = float(_pitches.get(layer, 1.0))


# ------------------------------------------------------------- 3. signals ------

## Transitions that are events, not levels. Everything is read from the live system
## objects - the same ones the resolver consults - and each edge is latched so a
## signal fires once per change rather than once per frame.
func _step_signals(p: ShipAudioParameters) -> void:
	if _ship.stabilization != null:
		var on := _ship.stabilization.enabled
		if on != _stabilizer_was:
			_stabilizer_was = on
			_play_event(EVENT_STAB_ON if on else EVENT_STAB_OFF)
	if _ship.emergency_brake != null:
		var engaged := _ship.emergency_brake.engaged
		if engaged and not _emergency_was:
			_play_event(EVENT_EMERGENCY)
		_emergency_was = engaged
	if _ship.boost != null:
		var lit := _ship.boost.active
		if lit and not _boost_was:
			_play_event(EVENT_BOOST_ON)
		_boost_was = lit
		_step_charge_signals(p)


## The boost tank's three announcements, with hysteresis on the low-charge one so a
## tank hovering at the threshold cannot blink. `_charge_was` is seeded on the first
## frame, so a hull that starts full does not announce "ready" at boot.
func _step_charge_signals(p: ShipAudioParameters) -> void:
	var charge := _ship.boost.boost_charge
	if charge < p.boost_low_charge and _charge_was >= p.boost_low_charge and _low_armed:
		_low_armed = false
		_play_event(EVENT_BOOST_LOW)
	if charge > p.boost_low_charge * 1.4:
		_low_armed = true
	if charge <= 0.001:
		# Dry. Announce the last drop once, then wait armed for the recovery.
		if not _empty_latched:
			_play_event(EVENT_BOOST_EMPTY)
		_empty_latched = true
	elif _empty_latched and charge >= p.boost_ready_charge:
		# Recovered enough to light the engine again: this is the "tank is back" cue.
		_empty_latched = false
		_play_event(EVENT_BOOST_READY)
	_charge_was = charge


func _on_collision(info: Dictionary) -> void:
	if not enabled:
		return
	var category := String(info.get("category", "LIGHT"))
	var event_name := EVENT_IMPACT_LIGHT
	if category == "HEAVY":
		event_name = EVENT_IMPACT_HEAVY
	elif category == "MEDIUM":
		event_name = EVENT_IMPACT_MEDIUM
	# The volume follows the *measured* closing speed, so a MEDIUM arrived at slowly
	# and a MEDIUM at the top of its band do not sound identical - and a LIGHT tap can
	# never be as loud as a HEAVY, because the normaliser is the heavy threshold.
	var span := 380.0
	if _ship != null and _ship.world != null:
		span = maxf(_ship.world.heavy_collision_threshold, 1.0)
	var intensity := clampf(float(info.get("closing_speed", 0.0)) / span, 0.18, 1.0)
	_play_event(event_name, intensity)


func _on_control_enabled() -> void:
	_play_event(EVENT_CONTROL_ON)


func _on_control_disabled() -> void:
	_play_event(EVENT_CONTROL_OFF)


# ------------------------------------------------------------- 4. one-shots ----

## Commit one short event: rate-limit it, count it, and play it on a free voice. The
## order matters - the limit is applied before the stream lookup, so the wiring is
## observable (and testable) in a project with no audio files at all.
func _play_event(event_name: String, intensity := 1.0) -> bool:
	if not enabled:
		return false
	var p := settings()
	var impact := _is_impact(event_name)
	var gap := p.impact_min_interval if impact else p.system_min_interval
	var now := _now()
	if now - float(_last_played.get(event_name, -1000.0)) < gap:
		return false
	if impact and now - float(_last_played.get(_IMPACT_GATE, -1000.0)) < gap:
		return false
	_last_played[event_name] = now
	if impact:
		_last_played[_IMPACT_GATE] = now
	_counts[event_name] = int(_counts.get(event_name, 0)) + 1

	var stream := _stream_for(event_name)
	var voice := _free_voice() if stream != null else null
	if voice == null:
		# Accepted and counted, but silent: either the file is absent or every voice
		# is busy. Neither is an error, and neither is allowed to steal a tail.
		sound_event.emit(event_name, -INF)
		return false
	voice.stream = stream
	voice.bus = AudioMixer.SHIP_IMPACTS if impact else AudioMixer.SHIP_SYSTEMS
	if not AudioMixer.has_bus(voice.bus):
		voice.bus = AudioMixer.MASTER
	var db := p.impact_volume_db + linear_to_db(clampf(intensity, 0.05, 1.0)) if impact \
		else p.system_volume_db
	voice.volume_db = db
	voice.pitch_scale = 1.0
	voice.play()
	sound_event.emit(event_name, db)
	return true


func _free_voice() -> AudioStreamPlayer:
	var count := _voices.size()
	for step in count:
		var index := (_voice_cursor + step) % count
		var voice := _voices[index]
		if not voice.playing:
			_voice_cursor = (index + 1) % count
			return voice
	return null


static func _is_impact(event_name: String) -> bool:
	return event_name == EVENT_IMPACT_LIGHT or event_name == EVENT_IMPACT_MEDIUM \
		or event_name == EVENT_IMPACT_HEAVY


## Physics time, the same clock the ship's own collision cooldowns use, so a test
## that steps the tree at its own pace sees the same intervals the game does.
func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


# ---------------------------------------------------------------- 5. quiet -----

## Silence every layer. Used by the master switch and by `_exit_tree`, so a ship
## removed mid-burn does not leave a hum hanging in the mixer for a frame.
func _hush() -> void:
	for layer in _loops:
		var player: AudioStreamPlayer = _loops[layer]
		if player.playing:
			player.stop()
		player.volume_db = SILENCE_DB
		_levels[layer] = 0.0
	for voice in _voices:
		if voice.playing:
			voice.stop()


func _exit_tree() -> void:
	_hush()


## Exponential settle with a frame-rate independent rate. Used for pitch, where the
## ear only notices that it moved, not when it arrived.
func _settle(current: float, target: float, time: float, delta: float) -> float:
	var rate := 1.0 - exp(-delta / maxf(time, 0.001))
	return lerpf(current, target, rate)