class_name AudioSettings

## The pilot's volume settings: four sliders, saved to `user://settings.cfg`
## and applied to the project's buses through `AudioMixer`.
##
##   master  -> Master          music   -> Music
##   effects -> Ship, Ambience  ui      -> UI

const PATH := "user://settings.cfg"
const SECTION := "audio"
const KEYS := ["master", "music", "effects", "ui"]
const DEFAULTS := {"master": 0.85, "music": 0.7, "effects": 0.85, "ui": 0.8}

static var _values: Dictionary = {}
static var _loaded: bool = false


static func load_and_apply() -> void:
	if _loaded:
		apply()
		return
	_loaded = true
	_values = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for key in KEYS:
			_values[key] = clampf(float(cfg.get_value(SECTION, key, DEFAULTS[key])), 0.0, 1.0)
	apply()


static func get_value(key: String) -> float:
	if not _loaded:
		load_and_apply()
	return float(_values.get(key, DEFAULTS.get(key, 1.0)))


static func set_value(key: String, value: float) -> void:
	if not _loaded:
		load_and_apply()
	_values[key] = clampf(value, 0.0, 1.0)
	apply()


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	for key in KEYS:
		cfg.set_value(SECTION, key, get_value(key))
	cfg.save(PATH)


static func apply() -> void:
	_apply_bus(AudioMixer.MASTER, _values.get("master", 1.0))
	_apply_bus(AudioMixer.MUSIC, _values.get("music", 1.0))
	_apply_bus(AudioMixer.SHIP, _values.get("effects", 1.0))
	_apply_bus(AudioMixer.AMBIENCE, _values.get("effects", 1.0))
	_apply_bus(AudioMixer.UI, _values.get("ui", 1.0))


static func _apply_bus(bus: StringName, linear: float) -> void:
	if not AudioMixer.has_bus(bus):
		return
	var v := clampf(float(linear), 0.0, 1.0)
	AudioMixer.set_muted(bus, v <= 0.001)
	AudioMixer.set_volume_linear(bus, maxf(v, 0.001))
