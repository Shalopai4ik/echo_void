extends InterfaceConsole
class_name MainMenuConsole

## The flight binding for the main menu.
##
## The game boots straight into the flight scene with this menu up, so the
## world waits behind it until the pilot presses "Начать исследование". A new
## run reloads the scene and skips the menu once, so the pilot lands in the
## flight. The pause menu and the end screen open it again in their own mode.
## In a scene that is not the running main scene (a test that builds the map
## by hand) the menu does not open by itself.

@onready var _menu_screen: MainMenuScreen = $Screen

var _clock: SessionClock = null

## Set before a reload: the next boot skips the menu.
static var _skip_next_boot: bool = false


func _ready() -> void:
	super._ready()
	panel_id = "main_menu"
	toggle_action = ""
	_menu_screen.continue_requested.connect(func() -> void: close_panel())
	_menu_screen.new_run_requested.connect(_on_new_run)
	_menu_screen.quit_requested.connect(func() -> void: get_tree().quit())
	refresh()
	call_deferred("_boot")


## Open on launch when this map is the game's running scene.
func _boot() -> void:
	var tree := get_tree()
	if tree == null or tree.current_scene == null or tree.current_scene != get_parent():
		return
	if _skip_next_boot:
		_skip_next_boot = false
		return
	open_in(MainMenuScreen.Mode.START)


## Open the menu in a given situation (start, running, finished).
func open_in(mode: int) -> void:
	_menu_screen.set_mode(mode)
	open_panel()


## The panel this console feeds.
func screen() -> InterfaceScreen:
	return _menu_screen


## The footer's one line: the run's own clock.
func refresh() -> void:
	if _menu_screen == null:
		return
	if _clock == null or not is_instance_valid(_clock):
		_clock = get_tree().get_first_node_in_group(SessionClock.GROUP) as SessionClock
	var status := "СЕССИЯ 01  ·  ВРЕМЯ 00:00:00"
	if _clock != null and is_instance_valid(_clock):
		status = _clock.status_text()
	_menu_screen.set_status(status)


## Opening from the pause menu goes through `open_panel_by_id("main_menu")`:
## that is the running-flight situation.
func _on_panel_opened() -> void:
	if _menu_screen.mode() == MainMenuScreen.Mode.START and _started():
		_menu_screen.set_mode(MainMenuScreen.Mode.RUNNING)
	super._on_panel_opened()


func _started() -> bool:
	var clock := get_tree().get_first_node_in_group(SessionClock.GROUP) as SessionClock
	return clock != null and clock.elapsed() > 0.5


## A new run: the flight scene is rebuilt from the start and the pilot lands
## straight in it. The clock's own counter survives.
func _on_new_run() -> void:
	var tree := get_tree()
	if tree == null:
		return
	_skip_next_boot = true
	tree.reload_current_scene()
