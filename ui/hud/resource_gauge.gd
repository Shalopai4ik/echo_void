extends VBoxContainer
class_name ResourceGauge

## Presentation-only gauge. It owns no game-system references.
## Stage 7 may call set_values() from a controller; the component itself
## only updates labels, fill percentage and visual severity.

enum Severity { NORMAL, WARNING, CRITICAL }

@onready var _label: Label = %Header.get_node("Label")
@onready var _value_label: Label = %Header.get_node("Value")
@onready var _bar: ProgressBar = %Bar

var _severity := Severity.NORMAL


func _ready() -> void:
	_apply_severity()


func set_values(current: float, maximum: float, label_text: String = "") -> void:
	var safe_maximum := maxf(maximum, 0.0)
	var safe_current := clampf(current, 0.0, safe_maximum)
	_bar.max_value = safe_maximum
	_bar.value = safe_current
	_value_label.text = "%d / %d" % [roundi(safe_current), roundi(safe_maximum)]
	if not label_text.is_empty():
		_label.text = label_text
	_apply_severity()


func set_severity(severity: Severity) -> void:
	_severity = severity
	_apply_severity()


func set_warning_threshold(ratio: float) -> void:
	_warning_ratio = clampf(ratio, 0.0, 1.0)
	_apply_severity()


func set_critical_threshold(ratio: float) -> void:
	_critical_ratio = clampf(ratio, 0.0, 1.0)
	_apply_severity()


func _apply_severity() -> void:
	var ratio := _bar.value / maxf(_bar.max_value, 1.0)
	var effective := _severity
	if effective == Severity.NORMAL:
		if ratio <= _critical_ratio:
			effective = Severity.CRITICAL
		elif ratio <= _warning_ratio:
			effective = Severity.WARNING

	var fill_color := Color(0.2, 0.72, 0.78, 0.94)
	var value_color := Color(0.82, 0.95, 0.98, 1)
	match effective:
		Severity.WARNING:
			fill_color = Color(0.92, 0.48, 0.18, 0.95)
			value_color = Color(1.0, 0.72, 0.4, 1)
		Severity.CRITICAL:
			fill_color = Color(0.85, 0.2, 0.18, 0.98)
			value_color = Color(1.0, 0.48, 0.42, 1)

	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	_bar.add_theme_stylebox_override("fill", fill)
	_value_label.add_theme_color_override("font_color", value_color)

var _warning_ratio := 0.5
var _critical_ratio := 0.25
