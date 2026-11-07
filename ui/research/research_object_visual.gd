class_name ResearchObjectVisual
extends Control

## Conditional visualization of one cosmic object. The picture is drawn from
## the object's kind, so no artwork is required and nothing is queried from the
## world. Purely decorative: it never receives input and never changes state.

var kind: String = "unknown":
	set(value):
		kind = value
		queue_redraw()

var accent: Color = Color(0.36, 0.86, 0.9, 1.0):
	set(value):
		accent = value
		queue_redraw()

## Draws a slow rotating scan ring over the object. Purely decorative.
var scanning: bool = false:
	set(value):
		if scanning == value:
			return
		scanning = value
		set_process(scanning)
		queue_redraw()

var _angle: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func _process(delta: float) -> void:
	_angle = fmod(_angle + delta * 0.9, TAU)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := maxf(8.0, minf(size.x, size.y) * 0.42)
	draw_circle(center, radius * 1.18, Color(accent.r, accent.g, accent.b, 0.05))
	draw_arc(center, radius * 1.18, 0.0, TAU, 48, Color(accent.r, accent.g, accent.b, 0.22), 1.0)
	match kind:
		"asteroid":
			_draw_asteroid(center, radius)
		"debris":
			_draw_debris(center, radius)
		"beacon":
			_draw_beacon(center, radius)
		"anomaly":
			_draw_anomaly(center, radius)
		"hazard":
			_draw_hazard(center, radius)
		"structure":
			_draw_structure(center, radius)
		_:
			_draw_unknown(center, radius)
	if scanning:
		_draw_scan_ring(center, radius)


func _draw_asteroid(center: Vector2, radius: float) -> void:
	var points := PackedVector2Array()
	var steps := 9
	for index in steps:
		var angle := TAU * float(index) / float(steps)
		var wobble := 0.78 + 0.22 * float((index * 5) % 3)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius * wobble)
	draw_colored_polygon(points, Color(accent.r, accent.g, accent.b, 0.16))
	draw_polyline(points + PackedVector2Array([points[0]]), accent, 1.0)
	draw_circle(center + Vector2(-radius * 0.22, -radius * 0.2), radius * 0.12, Color(accent.r, accent.g, accent.b, 0.35))


func _draw_debris(center: Vector2, radius: float) -> void:
	var offsets := [Vector2(-0.5, -0.35), Vector2(0.42, -0.2), Vector2(-0.1, 0.45), Vector2(0.5, 0.4)]
	for index in offsets.size():
		var offset: Vector2 = offsets[index]
		var half := radius * (0.2 if index % 2 == 0 else 0.14)
		var rect := Rect2(center + offset * radius - Vector2(half, half), Vector2(half * 2.0, half * 1.4))
		draw_rect(rect, Color(accent.r, accent.g, accent.b, 0.18))
		draw_rect(rect, accent, false, 1.0)


func _draw_beacon(center: Vector2, radius: float) -> void:
	for index in 3:
		var ring := radius * (0.4 + 0.28 * float(index))
		draw_arc(center, ring, 0.0, TAU, 32, Color(accent.r, accent.g, accent.b, 0.7 - 0.18 * float(index)), 1.0)
	draw_circle(center, radius * 0.16, accent)
	draw_line(center - Vector2(radius, 0.0), center + Vector2(radius, 0.0), Color(accent.r, accent.g, accent.b, 0.18), 1.0)
	draw_line(center - Vector2(0.0, radius), center + Vector2(0.0, radius), Color(accent.r, accent.g, accent.b, 0.18), 1.0)


func _draw_anomaly(center: Vector2, radius: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(0.0, -radius),
		center + Vector2(radius * 0.72, 0.0),
		center + Vector2(0.0, radius),
		center + Vector2(-radius * 0.72, 0.0),
	])
	draw_colored_polygon(points, Color(accent.r, accent.g, accent.b, 0.2))
	draw_polyline(points + PackedVector2Array([points[0]]), accent, 1.0)
	draw_arc(center, radius * 0.42, 0.0, TAU, 24, Color(accent.r, accent.g, accent.b, 0.6), 1.0)


func _draw_hazard(center: Vector2, radius: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(0.0, -radius),
		center + Vector2(radius * 0.86, radius * 0.7),
		center + Vector2(-radius * 0.86, radius * 0.7),
	])
	draw_colored_polygon(points, Color(accent.r, accent.g, accent.b, 0.22))
	draw_polyline(points + PackedVector2Array([points[0]]), accent, 1.0)
	draw_line(center + Vector2(0.0, -radius * 0.35), center + Vector2(0.0, radius * 0.2), accent, 1.0)
	draw_circle(center + Vector2(0.0, radius * 0.42), 1.0, accent)


func _draw_structure(center: Vector2, radius: float) -> void:
	var rect := Rect2(center - Vector2(radius, radius * 0.7), Vector2(radius * 2.0, radius * 1.4))
	draw_rect(rect, Color(accent.r, accent.g, accent.b, 0.14))
	draw_rect(rect, accent, false, 1.0)
	draw_line(rect.position, rect.position + rect.size, Color(accent.r, accent.g, accent.b, 0.5), 1.0)


func _draw_unknown(center: Vector2, radius: float) -> void:
	draw_arc(center, radius * 0.72, 0.0, TAU, 32, Color(accent.r, accent.g, accent.b, 0.75), 1.0)
	for index in 4:
		var start := _angle * 0.0 + TAU * float(index) / 4.0
		draw_arc(center, radius * 0.72, start, start + 0.5, 8, Color(accent.r, accent.g, accent.b, 0.28), 2.0)
	draw_line(center - Vector2(radius * 0.3, 0.0), center + Vector2(radius * 0.3, 0.0), accent, 1.0)


func _draw_scan_ring(center: Vector2, radius: float) -> void:
	var sweep := PackedVector2Array()
	sweep.append(center)
	for index in 12:
		var angle := _angle - 0.5 + 0.5 * float(index) / 11.0
		sweep.append(center + Vector2(cos(angle), sin(angle)) * radius * 1.18)
	draw_colored_polygon(sweep, Color(accent.r, accent.g, accent.b, 0.08))
	draw_line(center, center + Vector2(cos(_angle), sin(_angle)) * radius * 1.18,
		Color(accent.r, accent.g, accent.b, 0.6), 1.0)
