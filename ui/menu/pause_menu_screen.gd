extends InterfaceScreen
class_name PauseMenuScreen

## The pause menu: the way out of the flight and back into it.
##
## Every button here does something real. "Продолжить" gives the world back,
## "Настройки звука" opens the volume sliders, "Выйти в главное меню" opens
## the main menu, and the display button is the project's own window-mode
## switch. There is no button that only looks busy.
##
## Escape opens the menu when it is closed and closes it when it is open, and
## it never opens over another panel: one panel at a time is the rule of the
## whole interface.

signal resume_requested
signal menu_requested

@onready var _resume: Button = %Resume
@onready var _abort: Button = %Abort
@onready var _clock: Label = %Clock
@onready var _status: Label = %Status
@onready var _hint: Label = %Hint

var _settings_button: Button
var _settings: AudioSettingsPanel


func _ready() -> void:
	super._ready()
	_resume.pressed.connect(func() -> void: resume_requested.emit())
	_abort.pressed.connect(func() -> void: menu_requested.emit())
	_abort.text = "ВЫЙТИ В ГЛАВНОЕ МЕНЮ"
	var content := _resume.get_parent()
	_settings_button = Button.new()
	_settings_button.name = "Settings"
	_settings_button.text = "НАСТРОЙКИ ЗВУКА"
	content.add_child(_settings_button)
	content.move_child(_settings_button, _resume.get_index() + 1)
	_settings = AudioSettingsPanel.new()
	_settings.name = "AudioSettings"
	_settings.visible = false
	content.add_child(_settings)
	_settings_button.pressed.connect(func() -> void: _settings.visible = not _settings.visible)
	closed.connect(func() -> void: _settings.visible = false)


## The volume panel, for a test.
func settings_panel() -> AudioSettingsPanel:
	return _settings


func settings_button() -> Button:
	return _settings_button


## The clock and the status line: the run's own time and the hull's own state.
func set_status(clock_text: String, status_text: String) -> void:
	if not is_node_ready():
		return
	_clock.text = clock_text
	_status.text = status_text


## Escape opens the menu when it is closed and closes it when it is open.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if visible:
			super._input(event)
		elif get_tree().get_nodes_in_group(MODAL_GROUP).is_empty():
			open()
			get_viewport().set_input_as_handled()
		return
	super._input(event)
