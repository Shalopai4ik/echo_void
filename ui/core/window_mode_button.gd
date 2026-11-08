extends Button
class_name UiWindowModeButton

## Display-only control for switching between windowed and fullscreen modes.
## It does not touch gameplay state or pause handling.

enum ViewMode { WINDOWED, FULLSCREEN }

var _mode := ViewMode.WINDOWED


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	pressed.connect(_toggle)
	# A window that changed size has very likely changed mode too - an OS
	# fullscreen key, a drag between monitors - so the label is re-read then.
	get_viewport().size_changed.connect(_update_label)
	_update_label()


func _toggle() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_update_label()


## Read the window instead of a private flag: the same control sits on the main
## menu, the pause menu and the upgrades panel, and a copy that was opened after
## the window changed has to say what is true now.
func _update_label() -> void:
	_mode = ViewMode.FULLSCREEN \
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN \
		else ViewMode.WINDOWED
	text = "РЕЖИМ: ПОЛНЫЙ ЭКРАН" if _mode == ViewMode.FULLSCREEN else "РЕЖИМ: ОКНО"
