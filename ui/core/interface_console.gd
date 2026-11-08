extends CanvasLayer
class_name InterfaceConsole

## A panel that floats over the flight.
##
## The console is the layer between a screen and the ship: it owns the key
## that opens the panel, it feeds the screen from the live game state, and it
## turns the pilot's wishes back into calls on the real systems.
##
## Every console joins the `interface_panel` group and carries a `panel_id`,
## so one console can hand the screen over to another ("РЎРљРђРќР•Р " on the
## equipment panel opens the scanner screen) without knowing that console's
## class.

## The group every console joins.
const GROUP := "interface_panel"

## This console's name among the panels: "equipment", "scanner", "research",
## "upgrades", "pause", "main_menu".
@export var panel_id: String = ""
## The input action that opens and closes this panel. Empty means the panel is
## opened by something else - a button, or the game itself.
@export var toggle_action: String = ""
## Open the panel as soon as the scene starts.
@export var start_open: bool = false

## The screen this console drives.
var _panel: InterfaceScreen = null


func _ready() -> void:
	add_to_group(GROUP)
	# The console answers keys while the world is paused, so it must keep
	# running when the tree is held.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel = _find_panel()
	if _panel != null:
		_panel.opened.connect(_on_panel_opened)
		_panel.closed.connect(_on_panel_closed)
	if start_open:
		open_panel()
	else:
		close_panel()


## The screen this console drives, or null when the scene carries none.
func screen() -> InterfaceScreen:
	return _panel


func open_panel() -> void:
	if _panel != null:
		_panel.open()


func close_panel() -> void:
	if _panel != null:
		_panel.close()


func toggle_panel() -> void:
	if _panel != null:
		_panel.toggle()


func is_panel_open() -> bool:
	return _panel != null and _panel.is_open()


## Open another panel by its id. The pilot asked to go there, so the panel
## that is open now gives way - the screen base keeps only one up.
func open_panel_by_id(id: String) -> bool:
	for node in get_tree().get_nodes_in_group(GROUP):
		if node == self or not is_instance_valid(node):
			continue
		if str(node.get("panel_id")) != id:
			continue
		if node.has_method("open_panel"):
			node.call("open_panel")
			return true
	return false


## The console's own key. It is answered before the world sees it, so a panel
## can be opened and closed without the flight reacting.
func _input(event: InputEvent) -> void:
	if toggle_action.is_empty():
		return
	if event.is_action_pressed(toggle_action):
		toggle_panel()
		get_viewport().set_input_as_handled()


## The panel came up.
func _on_panel_opened() -> void:
	visible = true
	refresh()


## The panel went down.
func _on_panel_closed() -> void:
	visible = false


## Rebuild the screen from the live state. Called when the panel opens and
## whenever the ship says something changed.
func refresh() -> void:
	pass


## The screen under this console.
func _find_panel() -> InterfaceScreen:
	for child in get_children():
		if child is InterfaceScreen:
			return child
	return null
