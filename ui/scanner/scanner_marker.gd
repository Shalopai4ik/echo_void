class_name ScannerMarker
extends Control

## Small reusable radar marker. Shape and color encode the contact class;
## anomaly and unknown signals intentionally use the highest-contrast accents.

@export var marker_kind := "contact":
	set(value):
		marker_kind = value
		queue_redraw()

@export var selected := false:
	set(value):
		selected = value
		queue_redraw()

@export var label_text := "":
	set(value):
		label_text = value
		queue_redraw()

var _pulse := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(20.0, 20.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(marker_kind == "anomaly")


func _process(delta: float) -> void:
	_pulse = fmod(_pulse + delta * 2.2, TAU)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := 6.0
	var color := _marker_color()
	match marker_kind:
		"asteroid":
			draw_circle(center, radius, color)
			draw_arc(center, radius + 3.0, 0.0, TAU, 24, color * Color(1, 1, 1, 0.55), 1.0)
		"debris":
			_draw_diamond(center, radius + 1.0, color)
		"beacon":
			_draw_triangle(center, radius + 2.0, color)
		"anomaly":
			var pulse := 1.0 + sin(_pulse) * 0.16
			draw_rect(Rect2(center - Vector2(radius, radius) * pulse, Vector2(radius, radius) * pulse * 2.0), color, false, 1.5)
			draw_circle(center, 2.0, color)
		"unknown":
			draw_arc(center, radius, 0.0, TAU, 24, color, 1.5)
			draw_circle(center, 2.0, color)
		_:
			draw_circle(center, radius, color)
	if selected:
		draw_arc(center, radius + 5.0, 0.0, TAU, 32, Color(0.82, 0.98, 1.0, 0.95), 1.0)


func _marker_color() -> Color:
	match marker_kind:
		"anomaly":
			return Color(1.0, 0.36, 0.28, 1.0)
		"unknown":
			return Color(1.0, 0.68, 0.28, 1.0)
		"asteroid":
			return Color(0.42, 0.78, 0.82, 1.0)
		"debris":
			return Color(0.48, 0.9, 0.74, 1.0)
		"beacon":
			return Color(0.64, 0.7, 1.0, 1.0)
	return Color(0.36, 0.82, 0.88, 1.0)


func _draw_diamond(center: Vector2, radius: float, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -radius), center + Vector2(radius, 0),
		center + Vector2(0, radius), center + Vector2(-radius, 0),
	])
	draw_colored_polygon(points, color)


func _draw_triangle(center: Vector2, radius: float, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -radius),
		center + Vector2(radius * 0.86, radius * 0.65),
		center + Vector2(-radius * 0.86, radius * 0.65),
	])
	draw_colored_polygon(points, color)
