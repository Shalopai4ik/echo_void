extends PanelContainer
class_name CommsPanel

## Radio transmissions and logs: the story's voice, one line at a time.
##
## Lines arrive through `GameFeed.comms()` (group "comms"), queue up, and are
## typed out at a readable pace; each stays long enough to be read and then
## gives way to the next. Hints use a calmer colour; lost-crew recordings and
## stray signals are tinted warm. The panel never takes input.

const GROUP := "comms"
const CHARS_PER_SEC := 55.0

var _speaker: Label
var _text: Label
var _queue: Array = []
var _current: Dictionary = {}
var _shown: float = 0.0
var _hold: float = 0.0
## Every line said this run.
var log_lines: Array = []


func _ready() -> void:
	add_to_group(GROUP)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.008, 0.035, 0.055, 0.86)
	style.border_color = Color(0.12, 0.55, 0.68, 0.55)
	style.set_border_width_all(1)
	style.border_width_left = 3
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	add_child(box)
	_speaker = Label.new()
	_speaker.add_theme_font_size_override("font_size", 10)
	_speaker.add_theme_color_override("font_color", Color(0.3, 0.82, 0.87))
	box.add_child(_speaker)
	_text = Label.new()
	_text.add_theme_font_size_override("font_size", 12)
	_text.add_theme_color_override("font_color", Color(0.82, 0.95, 0.98))
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(430, 0)
	box.add_child(_text)
	visible = false


func say(speaker: String, text: String, tag: String = "") -> void:
	_queue.append({"speaker": speaker, "text": text, "tag": tag})
	log_lines.append("%s: %s" % [speaker, text])


func is_busy() -> bool:
	return not _current.is_empty() or not _queue.is_empty()


func _process(delta: float) -> void:
	if not get_tree().get_nodes_in_group("ui_modal").is_empty():
		return
	if _current.is_empty():
		if _queue.is_empty():
			visible = false
			return
		_current = _queue.pop_front()
		_shown = 0.0
		_hold = 0.0
		_speaker.text = str(_current["speaker"])
		var tone := Color(0.3, 0.82, 0.87)
		match str(_current["tag"]):
			"hint":
				tone = Color(0.62, 0.86, 0.6)
			"signal":
				tone = Color(1.0, 0.62, 0.35)
		_speaker.add_theme_color_override("font_color", tone)
		visible = true
		GameFeed.sfx(get_tree(), "comms_in", null, -6.0)
	var full := str(_current["text"])
	if _shown < full.length():
		_shown += delta * CHARS_PER_SEC
		_text.text = full.substr(0, int(_shown))
		_text.visible_characters = -1
	else:
		_text.text = full
		_hold += delta
		var need := 2.5 + full.length() * 0.045
		if _queue.size() > 2:
			need *= 0.6
		if _hold >= need:
			_current = {}
