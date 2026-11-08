extends Node
class_name SessionClock

## How long this run has been going, and how many runs the pilot has started.
##
## The clock counts the flight's own time and stands still while a panel holds
## the world, because a pause is not part of the run: the hull does not fly
## during it, the reactor does not burn, and the clock does not tick.
##
## The run counter survives a restart of the flight scene, so the main menu
## can say "SESSION 03" after the pilot has started three runs.

## The group this node joins, so the menus find the same clock.
const GROUP := "session_clock"

## The group an open interface panel joins. While it is not empty the world
## is held, and the clock waits with it.
const MODAL_GROUP := "ui_modal"

## How many runs this process has started. A static, so a restart of the
## flight scene does not reset the count.
static var _runs := 0

var _elapsed := 0.0


func _ready() -> void:
	add_to_group(GROUP)
	_runs += 1


func _process(delta: float) -> void:
	if _held():
		return
	_elapsed += delta


## Is the world held by a panel right now?
func _held() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	return not tree.get_nodes_in_group(MODAL_GROUP).is_empty()


## How long this run has been going, in seconds.
func elapsed() -> float:
	return _elapsed


## How many runs this process has started.
func runs() -> int:
	return _runs


## The run's own time, as the menus write it.
func time_text() -> String:
	var total := int(_elapsed)
	return "%02d:%02d:%02d" % [total / 3600, (total / 60) % 60, total % 60]


## One line for the menus' footers.
func status_text() -> String:
	return "СЕССИЯ %02d  ·  ВРЕМЯ %s" % [_runs, time_text()]
