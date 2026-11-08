extends InterfaceScreen
class_name RunEndScreen

## The end of a run: the demo completed, or the ship lost.
##
## A modal screen like every other panel, so the world is held behind it. It
## shows the mission's own closing text and the run's numbers (time, objects
## studied, Research XP, upgrades) and offers three real ways on: a new run,
## the main menu, or the exit.

signal new_run_requested
signal menu_requested
signal quit_requested

var _title: Label
var _text: Label
var _stats: Label
var _victory: bool = false


func _ready() -> void:
	close_on_cancel = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.01, 0.02, 0.9)
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_title)
	box.add_child(HSeparator.new())
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(480, 0)
	_text.add_theme_font_size_override("font_size", 12)
	box.add_child(_text)
	_stats = Label.new()
	_stats.add_theme_font_size_override("font_size", 11)
	_stats.add_theme_color_override("font_color", Color(0.3, 0.82, 0.87))
	box.add_child(_stats)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	for spec in [["НОВОЕ ИССЛЕДОВАНИЕ", new_run_requested], ["ГЛАВНОЕ МЕНЮ", menu_requested],
			["ВЫХОД", quit_requested]]:
		var b := Button.new()
		b.text = spec[0]
		var sig: Signal = spec[1]
		b.pressed.connect(func() -> void: sig.emit())
		row.add_child(b)
	super._ready()
	visible = false


func show_result(victory: bool, title: String, text: String, stats: Dictionary) -> void:
	_victory = victory
	_title.text = title
	_title.add_theme_color_override("font_color",
		Color(0.62, 0.96, 1.0) if victory else Color(1.0, 0.45, 0.38))
	_text.text = text
	_stats.text = "ВРЕМЯ: %s   ·   ИЗУЧЕНО ОБЪЕКТОВ: %d   ·   RESEARCH XP: %d   ·   УЛУЧШЕНИЙ: %d   ·   ГЛАВА: %d / 5" % [
		str(stats.get("time", "--")), int(stats.get("studied", 0)), int(stats.get("xp", 0)),
		int(stats.get("upgrades", 0)), int(stats.get("chapter", 1))]
	open()


func is_victory() -> bool:
	return _victory
