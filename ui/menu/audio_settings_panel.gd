extends PanelContainer
class_name AudioSettingsPanel

## Four volume sliders - общая, музыка, эффекты, интерфейс - wired straight to
## `AudioSettings`, which moves the buses at once and saves on close. Used by
## the main menu and the pause menu alike.

const ROWS := [
	["master", "ОБЩАЯ ГРОМКОСТЬ"],
	["music", "МУЗЫКА"],
	["effects", "ЗВУКИ КОРАБЛЯ И КОСМОСА"],
	["ui", "ИНТЕРФЕЙС И СИГНАЛЫ"],
]

var _sliders: Dictionary = {}
var _values: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(330, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	var title := Label.new()
	title.text = "НАСТРОЙКИ ЗВУКА"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.3, 0.82, 0.87))
	box.add_child(title)
	for row in ROWS:
		var key: String = row[0]
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		box.add_child(line)
		var label := Label.new()
		label.text = row[1]
		label.custom_minimum_size = Vector2(170, 0)
		label.add_theme_font_size_override("font_size", 10)
		line.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.custom_minimum_size = Vector2(110, 18)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = AudioSettings.get_value(key)
		line.add_child(slider)
		var value := Label.new()
		value.custom_minimum_size = Vector2(34, 0)
		value.add_theme_font_size_override("font_size", 10)
		value.text = "%d%%" % roundi(slider.value * 100.0)
		line.add_child(value)
		_sliders[key] = slider
		_values[key] = value
		slider.value_changed.connect(func(v: float) -> void:
			AudioSettings.set_value(key, v)
			value.text = "%d%%" % roundi(v * 100.0))
	visibility_changed.connect(func() -> void:
		if not visible:
			AudioSettings.save()
		else:
			for k in _sliders:
				(_sliders[k] as HSlider).set_value_no_signal(AudioSettings.get_value(k))
				(_values[k] as Label).text = "%d%%" % roundi(AudioSettings.get_value(k) * 100.0))


func slider(key: String) -> HSlider:
	return _sliders.get(key)
