class_name ResearchResults
extends VBoxContainer

## Reusable block that shows what an analysis revealed: the research XP that
## was granted, the properties that were discovered and the completion notice.
##
## Presentation-only. It receives a prepared `ResearchObject` snapshot and
## never queries the research system.

signal property_highlighted(property_text: String)

@onready var _xp_label: Label = %XpValue
@onready var _xp_caption: Label = %XpCaption
@onready var _properties_label: Label = %PropertiesLabel
@onready var _properties_box: VBoxContainer = %Properties
@onready var _notification: Label = %Notification
@onready var _notification_panel: PanelContainer = %NotificationPanel

var _reveal_tween: Tween


func configure(object: ResearchObject, animate: bool = true) -> void:
	_xp_label.text = "+%d" % object.xp_awarded
	_xp_caption.text = "RESEARCH XP" if object.xp_awarded > 0 else "RESEARCH XP НЕ НАЧИСЛЕН"
	_xp_label.add_theme_color_override("font_color",
		Color(0.48, 0.95, 0.84, 1.0) if object.xp_awarded > 0 else Color(0.42, 0.56, 0.6, 1.0))
	_properties_label.text = "ОТКРЫТЫЕ СВОЙСТВА / %d" % object.discovered_properties.size()
	for child in _properties_box.get_children():
		child.queue_free()
	for index in object.discovered_properties.size():
		var text := object.discovered_properties[index]
		var row := _make_property_row(text, index)
		_properties_box.add_child(row)
	_properties_box.visible = not object.discovered_properties.is_empty()
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	_reveal_tween = null
	if object.state == ResearchObject.State.COMPLETED:
		_notification_panel.visible = true
		_notification.text = object.notification if not object.notification.is_empty() else "АНАЛИЗ ЗАВЕРШЁН"
		if animate:
			_reveal_notification()
	else:
		_notification_panel.visible = false
		_notification.text = ""
	if animate:
		_reveal_properties()


func _make_property_row(text: String, index: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var marker := Label.new()
	marker.text = "▸"
	marker.add_theme_color_override("font_color", Color(0.46, 0.9, 0.84, 1.0))
	marker.add_theme_font_size_override("font_size", 10)
	row.add_child(marker)
	var value := Label.new()
	value.text = text
	value.add_theme_color_override("font_color", Color(0.72, 0.88, 0.91, 1.0))
	value.add_theme_font_size_override("font_size", 10)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value)
	row.set_meta("property_text", text)
	row.set_meta("property_index", index)
	return row


func _reveal_properties() -> void:
	var rows: Array[Control] = []
	for child in _properties_box.get_children():
		var control := child as Control
		if control != null:
			rows.append(control)
	if rows.is_empty():
		return
	_reveal_tween = create_tween()
	_reveal_tween.set_parallel(true)
	var index := 0
	for control in rows:
		control.modulate.a = 0.0
		_reveal_tween.tween_property(control, "modulate:a", 1.0, 0.28) \
			.set_delay(0.06 * float(index)) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		index += 1


func _reveal_notification() -> void:
	_notification_panel.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_notification_panel, "modulate:a", 1.0, 0.35) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_notification_panel, "modulate:a", 1.0, 0.6).set_delay(0.35)
