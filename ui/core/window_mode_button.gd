extends Button
class_name UiWindowModeButton

## Display-only control for switching between windowed and fullscreen modes.
## It does not touch gameplay state or pause handling.

enum ViewMode { WINDOWED, FULLSCREEN }

var _mode := ViewMode.WINDOWED


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	pressed.connect(_toggle)
	_update_label()


func _toggle() -> void:
	if _mode == ViewMode.WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_mode = ViewMode.FULLSCREEN
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_mode = ViewMode.WINDOWED
	_update_label()


func _update_label() -> void:
	text = "РЕЖИМ: ПОЛНЫЙ ЭКРАН" if _mode == ViewMode.FULLSCREEN else "РЕЖИМ: ОКНО"
