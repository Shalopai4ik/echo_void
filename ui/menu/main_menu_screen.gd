extends InterfaceScreen
class_name MainMenuScreen

## The main menu: the front door of the game and the way back out of a run.
##
## Three situations, one screen:
##
##   * START    - the game has just launched: "Начать исследование" lets the
##                flight (already built behind the menu) begin;
##   * RUNNING  - opened from the pause menu: "Продолжить" returns to the
##                flight, "Новое исследование" starts it again;
##   * FINISHED - the run is over (the demo was completed or the ship was
##                lost): only a new run or the exit make sense.
##
## "Настройки звука" opens the volume sliders, the display button is the
## project's window-mode switch, "Завершить сеанс" ends the program.

signal continue_requested
signal new_run_requested
signal quit_requested

enum Mode { START, RUNNING, FINISHED }

@onready var _continue: Button = %Continue
@onready var _new: Button = %New
@onready var _quit: Button = %Quit
@onready var _status: Label = %Status
@onready var _hint: Label = %Hint

var _mode: int = Mode.RUNNING
var _settings_button: Button
var _settings: AudioSettingsPanel


func _ready() -> void:
	super._ready()
	_continue.pressed.connect(func() -> void: continue_requested.emit())
	_new.pressed.connect(func() -> void: new_run_requested.emit())
	_quit.pressed.connect(func() -> void: quit_requested.emit())
	var grid := _continue.get_parent()
	_settings_button = Button.new()
	_settings_button.name = "Settings"
	_settings_button.text = "НАСТРОЙКИ ЗВУКА"
	grid.add_child(_settings_button)
	grid.move_child(_settings_button, _quit.get_index())
	_settings = AudioSettingsPanel.new()
	_settings.name = "AudioSettings"
	_settings.visible = false
	var center := grid.get_parent().get_parent()
	var layout := center.get_parent()
	layout.add_child(_settings)
	layout.move_child(_settings, center.get_index() + 1)
	_settings.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_settings_button.pressed.connect(func() -> void: _settings.visible = not _settings.visible)
	closed.connect(func() -> void: _settings.visible = false)
	_hint.text = "МЫШЬ  ВЫБОР   ·   WASD  ПОЛЁТ   ·   ESC  ПАУЗА"
	set_mode(_mode)


func set_mode(mode: int) -> void:
	_mode = mode
	if not is_node_ready():
		return
	close_on_cancel = mode == Mode.RUNNING
	match mode:
		Mode.START:
			_continue.visible = true
			_continue.text = "НАЧАТЬ ИССЛЕДОВАНИЕ"
			_new.visible = false
		Mode.RUNNING:
			_continue.visible = true
			_continue.text = "ПРОДОЛЖИТЬ"
			_new.visible = true
			_new.text = "НОВОЕ ИССЛЕДОВАНИЕ"
		Mode.FINISHED:
			_continue.visible = false
			_new.visible = true
			_new.text = "НОВОЕ ИССЛЕДОВАНИЕ"


func mode() -> int:
	return _mode


func settings_panel() -> AudioSettingsPanel:
	return _settings


## The footer's one line: the run's own clock.
func set_status(status_text: String) -> void:
	if not is_node_ready():
		return
	_status.text = status_text
