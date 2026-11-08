extends Control
class_name ResearchTicker

## One line at the top of the glass while the research desk works: what it
## studies, how far it got, and - when the hull has drifted out of range - that
## the analysis is waiting. Read from the desk's own `status()`.

var _desk: Node
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(300, 22)


func _process(delta: float) -> void:
	_time += delta
	if _desk == null or not is_instance_valid(_desk):
		_desk = GameNodes.device(get_tree(), "Research")
	queue_redraw()


func _draw() -> void:
	if _desk == null or not bool(_desk.call("is_researching")):
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var status: Dictionary = _desk.call("status")
	var progress := float(status.get("research_progress", 0.0))
	var waiting := bool(status.get("research_out_of_range", false))
	var type_label := str(status.get("research_type", ""))
	var profile: Variant = _desk.get("profile")
	if profile != null:
		var t: Variant = profile.call("type", type_label)
		if t != null:
			type_label = str(t.call("label"))
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.008, 0.035, 0.055, 0.8))
	var col := Color(0.5, 1.0, 0.8) if not waiting else Color(1.0, 0.62, 0.3, 0.6 + 0.4 * sin(_time * 6.0))
	draw_rect(Rect2(Vector2(0, size.y - 3), Vector2(size.x * progress, 3)), col)
	var text := "АНАЛИЗ: %s · %d%%" % [type_label.to_upper(), roundi(progress * 100.0)]
	if waiting:
		var d := float(_desk.call("subject_distance"))
		text = "АНАЛИЗ ЖДЁТ: ВЕРНИТЕСЬ К ОБЪЕКТУ (%d м)" % int(d / 10.0)
	draw_string(font, Vector2(8, 14), text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 16, 10, col)
