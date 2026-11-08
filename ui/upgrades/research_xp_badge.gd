class_name ResearchXpBadge
extends PanelContainer

## Compact research XP readout: a glyph, the caption and the running total.
##
## Presentation-only. It is fed a number by whoever holds it; a gain is what
## triggers the pulse, so the same badge can serve the flight HUD and the
## upgrades panel without either of them knowing about the other. Stage 7 will
## call `set_value()` from a controller that reads `ResearchSystem.get_xp()` and
## its `xp_gained` signal.

signal value_changed(value: int)

## Color the total flashes to when the pilot earns XP.
const PULSE_COLOR := Color(0.72, 1.0, 0.96, 1.0)
## Color the total flashes to when XP is spent on an upgrade.
const SPEND_COLOR := Color(1.0, 0.78, 0.42, 1.0)
const VALUE_COLOR := Color(0.82, 0.95, 0.98, 1.0)
const CAPTION_COLOR := Color(0.3, 0.82, 0.87, 1.0)

@onready var _icon: Label = %Icon
@onready var _value: Label = %Value
@onready var _delta: Label = %Delta

## The exact total, kept as an int so a gain can be measured.
var _value_exact: int = 0
var _pulse: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.text = "◈"
	_delta.visible = false
	_value.text = _format(0)


## Show `value` as the running total. When it is higher than the shown one and
## `animate` is on, the total pulses and a `+delta` flash appears.
func set_value(value: int, animate: bool = true) -> void:
	var next := maxi(value, 0)
	var previous := _value_exact
	_value_exact = next
	_value.text = _format(next)
	_value.add_theme_color_override("font_color", VALUE_COLOR)
	value_changed.emit(next)
	if next <= previous:
		_delta.visible = false
		return
	if animate:
		_flash(next - previous)


## Pulse the badge as if `amount` was just earned, without changing the total.
## Kept separate so a listener can react to a gain the panel already shows.
func flash(amount: int) -> void:
	if amount > 0:
		_flash(amount)


## Pulse the badge as a purchase: the total drops and the footer shows `−N`.
func flash_spend(amount: int) -> void:
	if amount <= 0:
		return
	_flash(amount, "−", SPEND_COLOR)


func value() -> int:
	return _value_exact


func _flash(amount: int, prefix: String = "+", color: Color = PULSE_COLOR) -> void:
	_delta.text = "%s%d" % [prefix, amount]
	_delta.visible = true
	_delta.modulate = Color(1, 1, 1, 1)
	_delta.add_theme_color_override("font_color", color)
	_value.add_theme_color_override("font_color", color)
	_icon.add_theme_color_override("font_color", color)
	if _pulse != null and _pulse.is_valid():
		_pulse.kill()
	_pulse = create_tween()
	_pulse.tween_property(_value, "modulate:a", 0.55, 0.12)
	_pulse.tween_property(_value, "modulate:a", 1.0, 0.5)
	_pulse.tween_property(_delta, "modulate:a", 0.0, 0.9)
	_pulse.tween_callback(_end_flash)


func _end_flash() -> void:
	_delta.visible = false
	_value.add_theme_color_override("font_color", VALUE_COLOR)
	_icon.add_theme_color_override("font_color", CAPTION_COLOR)


## Thousands separated by a thin space, the same shape `ResearchObject` uses.
func _format(value: int) -> String:
	var digits := str(absi(value))
	var grouped := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		grouped = digits[index] + grouped
		count += 1
		if count % 3 == 0 and index > 0:
			grouped = " " + grouped
	return ("-" if value < 0 else "") + grouped