extends InterfaceConsole
class_name ResearchConsole

## The flight binding for the research panel: the one place where the panel's
## list comes from and where its button becomes a real analysis.
##
## The console finds the ship's research desk and its scanner through the
## tree, keeps the last sweep's contacts so an object can still be ordered
## after the dish has moved on, and turns the panel's button into the desk's
## own `start_research()` and `cancel_research()`.

const SNAPSHOT := preload("res://ui/research/research_snapshot.gd")

@onready var _research_screen: ResearchScreen = $Screen

var _desk: Node = null
var _scanner: Node = null
var _hull: Node = null
## The contacts of the last sweep, by id. The desk orders an analysis by a
## contact, so the console keeps the contact even after the sweep is over.
var _contacts: Dictionary = {}


func _ready() -> void:
	super._ready()
	panel_id = "research"
	toggle_action = "toggle_research"
	_research_screen.research_requested.connect(_on_research_requested)
	_research_screen.research_pause_requested.connect(_on_research_pause_requested)
	_find_ship_parts()
	_connect_signals()
	refresh()


## The panel this console feeds.
func screen() -> InterfaceScreen:
	return _research_screen


## Rebuild the panel from the desk.
func refresh() -> void:
	if _research_screen == null:
		return
	if _desk == null or not is_instance_valid(_desk):
		_find_ship_parts()
	var snapshot := SNAPSHOT.build(_desk, _scanner)
	var objects: Array[ResearchObject] = []
	var raw: Variant = snapshot.get("objects", [])
	if raw is Array:
		for item in (raw as Array):
			if item is ResearchObject:
				objects.append(item as ResearchObject)
	_research_screen.set_live_objects(objects, int(snapshot.get("xp", 0)))


## The pilot ordered an analysis. The desk decides whether it can take it and
## pays out of its own budget.
func _on_research_requested(object_id: String) -> void:
	if _desk == null or not is_instance_valid(_desk):
		_find_ship_parts()
	if _desk == null or not is_instance_valid(_desk):
		return
	var contact := _contact_of(object_id)
	if contact.is_empty():
		return
	_desk.call("start_research", contact)
	refresh()


## The pilot stopped an analysis. The progress already spent is kept.
func _on_research_pause_requested(object_id: String) -> void:
	if _desk == null or not is_instance_valid(_desk):
		return
	_desk.call("cancel_research", "paused")
	refresh()


## The contact behind a subject, from the cache of the last sweeps.
func _contact_of(object_id: String) -> Dictionary:
	if _contacts.has(object_id):
		return _contacts[object_id]
	return {}


## The desk, the scanner and the hull, found through the tree.
func _find_ship_parts() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if _hull == null or not is_instance_valid(_hull):
		var ship := tree.get_first_node_in_group("player")
		if ship == null:
			ship = tree.get_first_node_in_group("ship")
		_hull = ship as Node2D
		if _hull != null:
			var systems := _hull.get_node_or_null("Systems")
			if systems != null:
				if _desk == null or not is_instance_valid(_desk):
					_desk = systems.get_node_or_null("Research")
				if _scanner == null or not is_instance_valid(_scanner):
					_scanner = systems.get_node_or_null("Scanner")
	if _scanner == null or not is_instance_valid(_scanner):
		_scanner = tree.get_first_node_in_group("scanner")


## The scanner's sweeps and the desk's events. Both have to reach the panel
## at once: a new subject and a finished analysis are two sides of the same
## number.
func _connect_signals() -> void:
	if _scanner != null and is_instance_valid(_scanner):
		for signal_name in ["scan_completed", "contact_found"]:
			if not _scanner.has_signal(signal_name):
				continue
			var callable := Callable(self, "_on_scanner_changed")
			if not _scanner.is_connected(signal_name, callable):
				_scanner.connect(signal_name, callable)
	if _desk != null and is_instance_valid(_desk):
		for signal_name in ["research_started", "research_progress",
				"research_completed", "research_cancelled", "xp_gained"]:
			if not _desk.has_signal(signal_name):
				continue
			var callable := Callable(self, "_on_desk_changed")
			if not _desk.is_connected(signal_name, callable):
				_desk.connect(signal_name, callable)


## The scanner found something: keep the contact, so the desk can still be
## ordered to analyse it later.
func _on_scanner_changed(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	if _scanner != null and is_instance_valid(_scanner) and _scanner.has_method("last_contacts"):
		var raw: Variant = _scanner.call("last_contacts")
		if raw is Array:
			for entry in (raw as Array):
				if entry is Dictionary:
					_contacts[str((entry as Dictionary).get("id", ""))] = entry as Dictionary
	refresh()


func _on_desk_changed(_a: Variant = null, _b: Variant = null, _c: Variant = null, _e: Variant = null,
		_d: Variant = null) -> void:
	refresh()
