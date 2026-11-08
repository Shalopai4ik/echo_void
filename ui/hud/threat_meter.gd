extends Control
class_name ThreatMeter

## The pilot's one window on the thing in the dark, in two readings:
##
##   * ШУМ - how loud the hull is right now (the creature's ear, live);
##   * АКТИВНОСТЬ - how much attention the hull has drawn, and the state the
##     instruments read off the disturbance ("тишина", "наблюдение", "поиск",
##     "сближение"...).
##
## Both numbers come from `ThreatAttention` and `Leviathan`; nothing here is
## estimated or invented. The panel stays dark until the mission wakes the
## listener up.

const ACCENT := Color(0.20, 0.78, 0.94)
const WARN := Color(1.0, 0.62, 0.3)
const HOT := Color(1.0, 0.3, 0.25)

var _att: ThreatAttention
var _lev: Leviathan
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(196, 40)


func _process(delta: float) -> void:
	_time += delta
	if _att == null or not is_instance_valid(_att):
		_att = get_tree().get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
	if _lev == null or not is_instance_valid(_lev):
		_lev = get_tree().get_first_node_in_group(Leviathan.GROUP) as Leviathan
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	if font == null or _att == null:
		return
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.008, 0.035, 0.055, 0.82))
	draw_rect(rect, Color(0.12, 0.55, 0.68, 0.5), false, 1.0)
	var awake := _att.threat_scale > 0.0
	var att := _att.attention() / 100.0
	var noise := clampf(_att.noise() / 1.2, 0.0, 1.0)
	var state_text := "НЕТ ДАННЫХ" if not awake else "ТИШИНА"
	var tone := ACCENT
	if _lev != null and awake:
		state_text = _lev.state_text()
		match _lev.state():
			Leviathan.State.INVESTIGATING:
				tone = WARN
			Leviathan.State.APPROACHING, Leviathan.State.MANIFEST:
				tone = HOT
	if not get_tree().get_nodes_in_group("brood").is_empty():
		state_text = "БИОСИГНАТУРЫ!"
		tone = HOT
	var blink := 1.0 if tone != HOT else 0.6 + 0.4 * sin(_time * 7.0)
	draw_string(font, Vector2(8, 13), "АКТИВНОСТЬ", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.57, 0.76, 0.84))
	draw_string(font, Vector2(78, 13), state_text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 84, 9, Color(tone, blink))
	_bar(Rect2(8, 18, size.x - 16, 5), att, tone)
	draw_string(font, Vector2(8, 35), "ШУМ", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.57, 0.76, 0.84))
	_bar(Rect2(40, 29, size.x - 48, 4), noise, WARN if noise > 0.5 else ACCENT)


func _bar(r: Rect2, ratio: float, col: Color) -> void:
	draw_rect(r, Color(0.01, 0.06, 0.1, 0.9))
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(ratio, 0.0, 1.0), r.size.y)), col)
