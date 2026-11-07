class_name ScannerScope
extends Control

## Radial scanner visualization. This component owns only presentation animation;
## it does not start, stop or otherwise control a scanner system.

const MARKER_SCENE := preload("res://scenes/ui/components/ScannerMarker.tscn")

var scanning := false:
	set(value):
		scanning = value
		queue_redraw()

var progress := 0.0:
	set(value):
		progress = clampf(value, 0.0, 1.0)
		queue_redraw()

var selected_contact_id := "":
	set(value):
		selected_contact_id = value
		_update_marker_selection()

var _contacts: Array[ScannerContact] = []
var _marker_nodes: Dictionary = {}
var _animation_time := 0.0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(delta: float) -> void:
	if scanning:
		_animation_time = fmod(_animation_time + delta * 0.72, TAU)
		queue_redraw()


func set_contacts(contacts: Array[ScannerContact]) -> void:
	_contacts = contacts
	for marker in _marker_nodes.values():
		if is_instance_valid(marker):
			marker.queue_free()
	_marker_nodes.clear()
	for contact in contacts:
		var marker := MARKER_SCENE.instantiate() as ScannerMarker
		marker.marker_kind = contact.marker_kind
		marker.label_text = contact.title
		marker.tooltip_text = "%s\n%s" % [contact.title, contact.type_label]
		add_child(marker)
		_marker_nodes[contact.id] = marker
	_update_marker_positions()
	_update_marker_selection()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_marker_positions()


func _draw() -> void:
	var center := size * 0.5
	var radius := maxf(24.0, minf(size.x, size.y) * 0.5 - 12.0)
	var dim := Color(0.2, 0.72, 0.78, 0.2)
	var bright := Color(0.36, 0.86, 0.9, 0.55)
	for ring in 3:
		var ring_radius := radius * (0.34 + 0.33 * ring)
		draw_arc(center, ring_radius, 0.0, TAU, 72, dim, 1.0)
	draw_line(center - Vector2(radius, 0), center + Vector2(radius, 0), dim, 1.0)
	draw_line(center - Vector2(0, radius), center + Vector2(0, radius), dim, 1.0)
	draw_arc(center, radius, 0.0, TAU, 96, bright, 1.0)
	if scanning:
		_draw_sweep(center, radius)
	draw_circle(center, 3.0, bright)


func _draw_sweep(center: Vector2, radius: float) -> void:
	var angle := _animation_time + progress * TAU
	var fade := Color(0.2, 0.82, 0.86, 0.0)
	for index in 14:
		var t := float(index) / 13.0
		var alpha := (1.0 - t) * 0.16
		var wave_radius := radius * (0.18 + t * 0.82)
		fade.a = alpha
		draw_arc(center, wave_radius, angle - 0.32 - t * 0.5, angle, 24, fade, 2.0)
	var wedge := PackedVector2Array()
	wedge.append(center)
	for index in 13:
		var a := angle - 0.55 + float(index) * 0.55 / 12.0
		wedge.append(center + Vector2(cos(a), sin(a)) * radius)
	draw_colored_polygon(wedge, Color(0.2, 0.82, 0.86, 0.07))
	draw_line(center, center + Vector2(cos(angle), sin(angle)) * radius, Color(0.52, 0.96, 1.0, 0.82), 1.5)


func _update_marker_positions() -> void:
	var center := size * 0.5
	var radius := maxf(18.0, minf(size.x, size.y) * 0.5 - 16.0)
	for contact in _contacts:
		var marker := _marker_nodes.get(contact.id) as ScannerMarker
		if marker == null or not is_instance_valid(marker):
			continue
		var offset := contact.normalized_position.limit_length(0.92) * radius
		marker.position = center + offset - marker.size * 0.5


func _update_marker_selection() -> void:
	for contact_id in _marker_nodes:
		var marker := _marker_nodes[contact_id] as ScannerMarker
		if marker != null and is_instance_valid(marker):
			marker.selected = contact_id == selected_contact_id
