extends Control
class_name WaypointMarker

## Points at the mission's next goal: a diamond over it when it is on the
## screen, an arrow on the edge of the glass when it is not, with the name and
## the distance. The goal comes from the mission's own `waypoint()`.

const COLOR := Color(1.0, 0.78, 0.35)
const MARGIN := 46.0
## The edge band the HUD panels own: the arrow stays inside it.
const INSET := Vector4(70.0, 120.0, 230.0, 110.0)  # left, top, right, bottom

var _mission: Node
var _ship: Node2D
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_time += delta
	if _mission == null or not is_instance_valid(_mission):
		_mission = get_tree().get_first_node_in_group("mission")
	if _ship == null or not is_instance_valid(_ship):
		_ship = GameNodes.ship(get_tree())
	queue_redraw()


func current_target() -> Dictionary:
	if _mission == null or not _mission.has_method("waypoint"):
		return {}
	return _mission.call("waypoint")


func _draw() -> void:
	var wp := current_target()
	if wp.is_empty() or _ship == null:
		return
	var font := get_theme_default_font()
	var world: Vector2 = wp["position"]
	var xf := get_viewport().get_canvas_transform()
	var screen := xf * world
	var area := get_viewport_rect().size
	var center := area * 0.5
	var view := Rect2(Vector2(INSET.x, INSET.y),
		(area - Vector2(INSET.x + INSET.z, INSET.y + INSET.w)).max(Vector2.ONE))
	center = view.get_center()
	var dist := int(_ship.global_position.distance_to(world) / 10.0)
	var label := "%s · %d м" % [str(wp["label"]), dist]
	var pulse := 0.75 + 0.25 * sin(_time * 3.0)
	var col := Color(COLOR, pulse)
	if view.has_point(screen):
		var s := 9.0
		draw_polyline(PackedVector2Array([screen + Vector2(0, -s), screen + Vector2(s, 0),
			screen + Vector2(0, s), screen + Vector2(-s, 0), screen + Vector2(0, -s)]), col, 2.0, true)
		if font != null:
			draw_string(font, screen + Vector2(14, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)
		return
	var dir := (screen - center).normalized()
	# walk from the centre to the edge of the inner frame
	var tx := INF if is_zero_approx(dir.x) else (view.size.x * 0.5) / absf(dir.x)
	var ty := INF if is_zero_approx(dir.y) else (view.size.y * 0.5) / absf(dir.y)
	var p := center + dir * minf(tx, ty)
	var side := dir.orthogonal()
	draw_colored_polygon(PackedVector2Array([p + dir * 12.0, p + side * 7.0, p - side * 7.0]), col)
	if font != null:
		var text_at := p - dir * 22.0 + Vector2(-40, 4)
		text_at.x = clampf(text_at.x, 8.0, maxf(area.x - 120.0, 8.0))
		draw_string(font, text_at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)
