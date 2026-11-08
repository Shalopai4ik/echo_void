extends Node2D
class_name SoundBank

## Every one-shot sound of the game outside the ship's own engine audio.
##
## Played by name through `GameFeed.sfx()` (group "sound_fx"). A name maps to
## `assets/audio/sfx/<name>.wav` (or the ship set). With a world position the
## sound is played positionally from a small pool of `AudioStreamPlayer2D`, so
## the brood and the flares are heard where they are; without one it plays
## flat. Each name has its bus (ambience, interface, ship systems) and a short
## repeat guard so a burst of events never stacks the same sound.
##
## It also gives every button in the game its click, by watching nodes enter
## the tree - no screen has to know about it.

const GROUP := "sound_fx"
const DIRS := ["res://assets/audio/sfx/", "res://assets/audio/ship/"]
const FLAT_VOICES := 8
const SPATIAL_VOICES := 6
const MIN_REPEAT_SEC := 0.09

const BUS_OF := {
	"creature_call": &"Ambience", "creature_near": &"Ambience", "creature_roar": &"Ambience",
	"tremor": &"Ambience", "radio_static": &"Ambience", "phantom_ping": &"Ambience",
	"ui_click": &"UI", "ui_confirm": &"UI", "comms_in": &"UI", "upgrade": &"UI",
	"refuse": &"UI", "warning": &"UI", "alarm": &"UI", "discover": &"UI",
	"scan_done": &"UI", "research_done": &"UI",
}
const LEVEL_DB := {
	"ui_click": -10.0, "comms_in": -8.0, "scan": -4.0, "radio_static": -6.0,
	"creature_call": -2.0, "alarm": -5.0, "warning": -5.0, "refuse": -8.0,
	"brood_emerge": -3.0, "power_flicker": -6.0,
}

var _cache: Dictionary = {}
var _last_played: Dictionary = {}
var _flat: Array[AudioStreamPlayer] = []
var _spatial: Array[AudioStreamPlayer2D] = []
var _flat_next := 0
var _spatial_next := 0
## Names played this run, newest last (for tests and the debug log).
var played: Array[String] = []


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	AudioSettings.load_and_apply()
	for i in FLAT_VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_flat.append(p)
	for i in SPATIAL_VOICES:
		var p := AudioStreamPlayer2D.new()
		p.max_distance = 4200.0
		p.attenuation = 1.4
		p.panning_strength = 0.8
		add_child(p)
		_spatial.append(p)
	get_tree().node_added.connect(_on_node_added)
	_warm()


## Load every effect once at start: a first alarm or a first roar must not
## stall the frame it plays on.
func _warm() -> void:
	for dir in DIRS:
		for file in ResourceLoader.list_directory(dir):
			if file.ends_with(".wav"):
				_stream(file.get_basename())


func play(name: String, at: Variant = null, volume_db: float = 0.0) -> void:
	var stream := _stream(name)
	if stream == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last_played.get(name, -10.0)) < MIN_REPEAT_SEC:
		return
	_last_played[name] = now
	played.append(name)
	if played.size() > 200:
		played.remove_at(0)
	var db := volume_db + float(LEVEL_DB.get(name, 0.0))
	var bus: StringName = BUS_OF.get(name, &"ShipSystems")
	if not AudioMixer.has_bus(bus):
		bus = &"Master"
	if at is Vector2:
		var sp := _spatial[_spatial_next]
		_spatial_next = (_spatial_next + 1) % _spatial.size()
		sp.stream = stream
		sp.bus = bus
		sp.volume_db = db
		sp.global_position = at
		sp.play()
	else:
		var p := _flat[_flat_next]
		_flat_next = (_flat_next + 1) % _flat.size()
		p.stream = stream
		p.bus = bus
		p.volume_db = db
		p.play()


func has_sound(name: String) -> bool:
	return _stream(name) != null


func _stream(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var found: AudioStream = null
	for dir in DIRS:
		var path: String = dir + name + ".wav"
		if ResourceLoader.exists(path):
			found = load(path) as AudioStream
			break
	_cache[name] = found
	return found


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		var button := node as BaseButton
		if not button.pressed.is_connected(_on_button):
			button.pressed.connect(_on_button)


func _on_button() -> void:
	play("ui_click")
