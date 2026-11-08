extends InterfaceConsole
class_name PauseMenuConsole

## The flight binding for the pause menu.
##
## The menu itself is a modal screen: while it is up the world is held, so
## the hull, the stones and the timers stand still. This node feeds the menu
## the run's own clock and the hull's own state, and turns the menu's buttons
## into real orders.

@onready var _pause_screen: PauseMenuScreen = $Screen

var _clock: SessionClock = null
var _ship: Node = null
var _systems: Node = null


func _ready() -> void:
	super._ready()
	panel_id = "pause"
	# The menu has no key of its own: Escape is handled by the screen, so the
	# same key opens and closes it and never opens over another panel.
	toggle_action = ""
	_pause_screen.resume_requested.connect(func() -> void: close_panel())
	_pause_screen.menu_requested.connect(func() -> void: open_panel_by_id("main_menu"))
	_find_ship_parts()
	refresh()


## The panel this console feeds.
func screen() -> InterfaceScreen:
	return _pause_screen


## The menu's own lines: the run's clock and the hull's state.
func refresh() -> void:
	if _pause_screen == null:
		return
	if _clock == null or not is_instance_valid(_clock):
		_clock = get_tree().get_first_node_in_group(SessionClock.GROUP) as SessionClock
	if _ship == null or not is_instance_valid(_ship):
		_find_ship_parts()
	var clock_text := "ВРЕМЯ 00:00:00"
	if _clock != null and is_instance_valid(_clock):
		clock_text = _clock.time_text()
	_pause_screen.set_status(clock_text, _ship_status())


## What the hull is doing right now, in the menu's own words.
func _ship_status() -> String:
	if _ship == null or not is_instance_valid(_ship):
		return "КОРАБЛЬ: НЕТ СВЯЗИ"
	var speed := 0
	if _ship.has_method("speed"):
		speed = int(_ship.call("speed"))
	var energy := 0
	if _systems != null and is_instance_valid(_systems) and _systems.has_method("energy_ratio"):
		energy = int(roundf(float(_systems.call("energy_ratio")) * 100.0))
	return "СКОРОСТЬ %d px/s  ·  ЗАРЯД %d%%  ·  ПАНЕЛЬ УПРАВЛЕНИЯ ОТКЛЮЧЕНА" % [speed, energy]


## The hull and its hub, found through the tree.
func _find_ship_parts() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if _ship == null or not is_instance_valid(_ship):
		_ship = tree.get_first_node_in_group("player")
		if _ship == null:
			_ship = tree.get_first_node_in_group("ship")
	if _ship != null and is_instance_valid(_ship):
		_systems = _ship.get_node_or_null("Systems")
