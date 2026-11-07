extends Control
class_name UiViewportPolicy

## Shared UI scaling policy. The project uses canvas_items + expand, so the
## logical canvas grows on the longer axis and never letterboxes. This policy
## keeps the real window above a usable minimum and exposes a consistent safe
## inset for all interface screens.

const MIN_WINDOW_SIZE := Vector2i(640, 360)
const BASE_SAFE_INSET := 16.0
const COMPACT_BREAKPOINT := 720.0
const COMPACT_SAFE_INSET := 8.0

@export var minimum_window_size := MIN_WINDOW_SIZE
@export var base_safe_inset := BASE_SAFE_INSET
@export var compact_breakpoint := COMPACT_BREAKPOINT
@export var compact_safe_inset := COMPACT_SAFE_INSET

var _window: Window


func _ready() -> void:
	_window = get_window()
	if _window != null:
		_window.min_size = minimum_window_size
		_window.size_changed.connect(_on_window_size_changed)
	_on_window_size_changed()


func safe_inset() -> float:
	var width := get_viewport_rect().size.x
	return compact_safe_inset if width < compact_breakpoint else base_safe_inset


func _on_window_size_changed() -> void:
	# Containers use the current viewport rect; this callback exists so custom
	# policies can be added without changing every screen.
	pass
