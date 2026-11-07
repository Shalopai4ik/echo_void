extends PanelContainer
class_name SystemNotificationItem

## One reusable visual-only notification row.

enum Kind { INFO, WARNING, PROBLEM }

@onready var _accent: ColorRect = $Content/Accent
@onready var _title_label: Label = %Title
@onready var _message_label: Label = %Message


func configure(kind: Kind, title_text: String, message_text: String) -> void:
	_title_label.text = title_text
	_message_label.text = message_text
	var accent := Color(0.3, 0.82, 0.87, 1)
	var title_color := Color(0.3, 0.82, 0.87, 1)
	match kind:
		Kind.WARNING:
			accent = Color(0.95, 0.52, 0.2, 1)
			title_color = Color(1.0, 0.68, 0.35, 1)
		Kind.PROBLEM:
			accent = Color(0.9, 0.24, 0.2, 1)
			title_color = Color(1.0, 0.45, 0.38, 1)
	_accent.color = accent
	_title_label.add_theme_color_override("font_color", title_color)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.008, 0.035, 0.055, 0.9)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.1, 0.42, 0.52, 0.48)
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_right = 2
	style.corner_radius_bottom_left = 2
	style.content_margin_left = 8.0
	style.content_margin_top = 6.0
	style.content_margin_right = 8.0
	style.content_margin_bottom = 6.0
	add_theme_stylebox_override("panel", style)
