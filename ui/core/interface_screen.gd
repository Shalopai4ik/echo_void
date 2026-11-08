extends UiViewportPolicy
class_name InterfaceScreen

## A modal interface screen that owns the world while it is open.
##
## One rule for every screen the pilot can open over the flight:
##
##   1. an open screen joins the `ui_modal` group - the flight HUD and the
##      scanner already ask that group before they answer a control key;
##   2. while that panel is open the world is held: the physics server is off
##      and the hull and the field of stones stop processing, so the ship, the
##      stones, the world streaming and the ship timers all stop exactly where
##      they were;
##   3. only one screen is open at a time - opening one closes the others;
##   4. Escape closes the screen, and the world comes back by itself.
##
## The hold belongs to the *group*, not to one screen: a screen that is closed
## while another one is open must not let the world go, so the world is
## released only when the group runs empty. Velocities are never written on
## the way in or out: the server is switched off, so the hull keeps the px/s
## and the rad/s it had and continues with them.
##
## The screen keeps its own `process_mode` (ALWAYS) so it still draws and
## still takes clicks while the world is held.

## The panel became visible.
signal opened
## The panel was hidden.
signal closed

## The group every open modal panel joins. Kept in step with `scripts/hud.gd`.
const MODAL_GROUP := "ui_modal"
## World nodes outside the hull and the field that must stop with the world.
const WORLD_PAUSABLE_GROUP := "world_pausable"

## Whether Escape closes this screen. The main menu is a root state of the
## session, not a panel over the flight, and it says so.
@export var close_on_cancel: bool = true

## True while this screen is closing the other open panels, so a close that
## comes back here cannot start another round.
var _closing_others: bool = false

## How many panels hold the world right now. The hold belongs to the group,
## not to one screen: when one panel takes the world over from another, the
## first one lets go and the second one keeps holding - the world must not
## flicker back to life for a frame in between.
static var _hold_count: int = 0
## The nodes whose processing was stopped for the hold, and the modes they
## had before, so the world comes back exactly as it was.
static var _held_nodes: Array[Node] = []
static var _held_modes: Dictionary = {}


## ------------------------------------------------------------------ opening ---

## Show the screen and take the world. Idempotent: opening an open screen does
## nothing, so a key press cannot stack two pauses on one panel.
func open() -> void:
	if visible:
		return
	visible = true
	add_to_group(MODAL_GROUP)
	_hold_world()
	_close_others()
	opened.emit()


## Hide the screen and give the world back - unless another panel is still
## open, in which case the world stays paused for that one.
func close() -> void:
	if not visible:
		return
	visible = false
	remove_from_group(MODAL_GROUP)
	_release_world()
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func is_open() -> bool:
	return visible


## Escape closes the panel. The event is consumed, so the pause menu and the
## flight controls never see the same key.
func _input(event: InputEvent) -> void:
	if not close_on_cancel or not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## A screen that is freed while it is open must not leave the game paused.
func _exit_tree() -> void:
	if is_in_group(MODAL_GROUP):
		remove_from_group(MODAL_GROUP)
	_release_world()


## ----------------------------------------------------------------- internals ---

## Stop the world, in two pieces:
##
##   * the physics server is switched off, so no body moves and no body is
##     written to - the hull keeps the px/s and the rad/s it had;
##   * the hull and the world field stop processing, so nothing ticks: no
##     flight model, no energy clock, no scanner sweep, no world streaming.
##
## The tree itself is deliberately **not** paused. Godot 4.7's 2D physics
## server keeps a list of the awake bodies and rebuilds it when the simulation
## resumes; with the tree paused and the server still running, that rebuild
## walks a list the paused frames never cleaned, the server trips an internal
## check (`p_elem->_root` in `core/templates/self_list.h`) and takes the
## process down with it. Measured on this very scene - see
## `docs/stage7_report.md`. Switching the server off first leaves the world
## exactly where it was: position, linear velocity and angular velocity come
## back bit for bit.
func _hold_world() -> void:
	_hold_count += 1
	if _hold_count > 1:
		return
	PhysicsServer2D.set_active(false)
	ShipSystemEvent.hold_clock()
	_held_nodes = _find_world_nodes()
	for node in _held_nodes:
		_held_modes[node.get_instance_id()] = node.process_mode
		node.process_mode = Node.PROCESS_MODE_DISABLED


## Give the world back, but only when no other panel is holding it.
func _release_world() -> void:
	if _hold_count <= 0:
		return
	_hold_count -= 1
	if _hold_count > 0:
		return
	for node in _held_nodes:
		if not is_instance_valid(node):
			continue
		var mode: int = int(_held_modes.get(node.get_instance_id(),
			Node.PROCESS_MODE_INHERIT))
		node.process_mode = mode
	_held_nodes.clear()
	_held_modes.clear()
	ShipSystemEvent.release_clock()
	PhysicsServer2D.set_active(true)


## The two things that make the world move: the hull and the field of stones.
## Both are found through the groups the ship and the field already join, so
## this file names no class of either.
func _find_world_nodes() -> Array[Node]:
	var out: Array[Node] = []
	var tree := get_tree()
	if tree == null:
		return out
	var hull := tree.get_first_node_in_group("player")
	if hull == null:
		hull = tree.get_first_node_in_group("ship")
	if hull != null:
		out.append(hull)
	var field := tree.get_first_node_in_group("world_field")
	if field != null and not out.has(field):
		out.append(field)
	# Everything else that lives in the world and moves on its own: the
	# creature, its brood, decoys and flares in flight, the mission director,
	# the atmosphere. They join this group themselves.
	for node in tree.get_nodes_in_group(WORLD_PAUSABLE_GROUP):
		if not out.has(node):
			out.append(node)
	return out


## Close every other open panel. Two panels at once would mean two owners of
## the pause and two owners of the keys; the last one opened wins.
func _close_others() -> void:
	if _closing_others:
		return
	_closing_others = true
	for node in get_tree().get_nodes_in_group(MODAL_GROUP):
		if node == self or not is_instance_valid(node):
			continue
		if node.has_method("close"):
			node.call("close")
	_closing_others = false
