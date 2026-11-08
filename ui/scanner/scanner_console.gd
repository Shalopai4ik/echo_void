extends InterfaceConsole
class_name ScannerConsole

## The flight binding for the scanner scope: the one place where the scope's
## numbers come from and where its button becomes a real sweep.
##
## The console finds the ship's scanner, its research desk and its hull
## through the tree - never through a global - and hands the screen a
## `ScannerSnapshot` built from what those three say right now. The button
## asks the real scanner for a real sweep and the refusal comes back in the
## pilot's own words.

const SNAPSHOT := preload("res://ui/scanner/scanner_snapshot.gd")

@onready var _scanner_screen: ScannerScreen = $Screen

var _scanner: Node = null
var _desk: Node = null
var _hull: Node2D = null
var _hub: Node = null
var _notice: String = ""


func _ready() -> void:
	super._ready()
	panel_id = "scanner"
	toggle_action = "toggle_scanner"
	_scanner_screen.scan_requested.connect(_on_scan_requested)
	_find_ship_parts()
	_connect_signals()
	refresh()


## The panel this console feeds.
func screen() -> InterfaceScreen:
	return _scanner_screen


## Rebuild the scope from the ship.
func refresh() -> void:
	if _scanner_screen == null:
		return
	if _scanner == null or not is_instance_valid(_scanner):
		_find_ship_parts()
	var energy := 1.0
	if _hub != null and is_instance_valid(_hub) and _hub.has_method("energy_ratio"):
		energy = float(_hub.call("energy_ratio"))
	_scanner_screen.set_live_state(SNAPSHOT.build(_scanner, _desk, _hull, energy))


## The pilot asked for a sweep. The scanner decides whether it can pay for one;
## the refusal is the scanner's own word.
func _on_scan_requested() -> void:
	if _scanner == null or not is_instance_valid(_scanner):
		_find_ship_parts()
	if _scanner == null or not is_instance_valid(_scanner):
		return
	var started := false
	if _scanner.has_method("start_scan"):
		started = bool(_scanner.call("start_scan"))
	if not started and _scanner.has_method("refuse_reason"):
		_notice = _reason_text(str(_scanner.call("refuse_reason")))
	refresh()


## The scanner's refusal, in the pilot's own words.
func _reason_text(reason: String) -> String:
	match reason:
		"cooldown":
			return "ОТКАЗ · ПЕРЕЗАРЯДКА"
		"energy":
			return "ОТКАЗ · НЕДОСТАТОЧНО ЭНЕРГИИ"
		"disabled":
			return "ОТКАЗ · СКАНЕР ВЫКЛЮЧЁН"
		"destroyed":
			return "ОТКАЗ · КОРАБЛЬ РАЗРУШЕН"
		"busy":
			return "ОТКАЗ · ОБХОД УЖЕ ИДЁТ"
	return "ОТКАЗ · %s" % reason.to_upper()


## The scanner, the desk, the hull and the hub, found through the tree.
func _find_ship_parts() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if _scanner == null or not is_instance_valid(_scanner):
		_scanner = tree.get_first_node_in_group("scanner")
	if _hull == null or not is_instance_valid(_hull):
		var ship := tree.get_first_node_in_group("player")
		if ship == null:
			ship = tree.get_first_node_in_group("ship")
		_hull = ship as Node2D
		if _hull != null:
			var systems := _hull.get_node_or_null("Systems")
			if systems != null:
				_hub = systems
				if _desk == null or not is_instance_valid(_desk):
					_desk = systems.get_node_or_null("Research")
				if _scanner == null or not is_instance_valid(_scanner):
					_scanner = systems.get_node_or_null("Scanner")


## The scanner's own signals: a sweep that starts, ends or is refused must
## show up in the scope at once.
func _connect_signals() -> void:
	if _scanner == null or not is_instance_valid(_scanner):
		return
	for signal_name in ["scan_started", "scan_completed", "contact_found", "scan_refused"]:
		if not _scanner.has_signal(signal_name):
			continue
		var callable := Callable(self, "_on_scanner_changed")
		if not _scanner.is_connected(signal_name, callable):
			_scanner.connect(signal_name, callable)


func _on_scanner_changed(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	refresh()
