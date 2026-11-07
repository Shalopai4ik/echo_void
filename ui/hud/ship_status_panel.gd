extends PanelContainer
class_name ShipStatusPanel

## Presentation-only ship telemetry panel. It does not query the ship or
## any other gameplay system.

@onready var _status_label: Label = %Status
@onready var _speed_label: Label = %SpeedValue
@onready var _hull_gauge: ResourceGauge = %HullGauge
@onready var _energy_gauge: ResourceGauge = %EnergyGauge

var _state := "НОРМА"


func apply_data(data: HudVisualData) -> void:
	if data == null:
		return
	_hull_gauge.set_warning_threshold(data.hull_warning_ratio)
	_hull_gauge.set_critical_threshold(data.hull_critical_ratio)
	_hull_gauge.set_values(data.hull_current, data.hull_maximum, "ПРОЧНОСТЬ КОРПУСА")
	_energy_gauge.set_warning_threshold(data.energy_warning_ratio)
	_energy_gauge.set_critical_threshold(data.energy_critical_ratio)
	_energy_gauge.set_values(data.energy_current, data.energy_maximum, "ЭНЕРГИЯ")
	_speed_label.text = "%d %s" % [roundi(data.speed), data.speed_unit]
	set_state(data.ship_state)


func set_state(state_text: String) -> void:
	_state = state_text.to_upper()
	var status_color := Color(0.48, 0.9, 0.84, 1)
	var border_color := Color(0.12, 0.55, 0.68, 0.58)
	match _state:
		"ПОВРЕЖДЕНИЕ":
			status_color = Color(1.0, 0.66, 0.32, 1)
			border_color = Color(0.85, 0.42, 0.16, 0.78)
		"КРИТИЧЕСКОЕ":
			status_color = Color(1.0, 0.4, 0.34, 1)
			border_color = Color(0.85, 0.18, 0.16, 0.88)
	_status_label.text = "● %s" % _state
	_status_label.add_theme_color_override("font_color", status_color)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.008, 0.035, 0.055, 0.92)
	panel_style.border_width_left = 1
	panel_style.border_width_top = 1
	panel_style.border_width_right = 1
	panel_style.border_width_bottom = 1
	panel_style.border_color = border_color
	panel_style.corner_radius_top_left = 2
	panel_style.corner_radius_top_right = 2
	panel_style.corner_radius_bottom_right = 2
	panel_style.corner_radius_bottom_left = 2
	panel_style.content_margin_left = 12.0
	panel_style.content_margin_top = 9.0
	panel_style.content_margin_right = 12.0
	panel_style.content_margin_bottom = 9.0
	add_theme_stylebox_override("panel", panel_style)
