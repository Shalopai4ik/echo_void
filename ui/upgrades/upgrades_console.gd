class_name UpgradesConsole
extends InterfaceConsole

## The flight binding for the upgrades panel: the one place where a button press
## becomes a purchase.
##
## The panel (`UpgradesScreen`) is presentation-only and the manager
## (`ResearchUpgradeManager`) is gameplay-only. This node joins them:
##
##   1. finds the manager mounted under `Ship/Systems`, exactly like the manager
##      finds the research desk - through the tree, never a global;
##   2. builds the panel's snapshot from the manager's levels and the mounted
##      devices' live values (`UpgradesSnapshot`);
##   3. turns `upgrade_requested` into a single `purchase()` call;
##   4. refreshes XP, levels, values, prices and the button state from the
##      manager's own signals, so a refusal or an outside XP change can never
##      leave the panel disagreeing with the ship;
##   5. reports the result in the panel's footer.
##
## It does not own XP, levels, costs or save data: the manager and the catalogue
## resource do. Removing this node from the scene leaves the game running, only
## without the panel - which is what every headless ship suite relies on.

const SNAPSHOT := preload("res://ui/upgrades/upgrades_snapshot.gd")

@onready var _screen: UpgradesScreen = $Screen

## The upgrade desk found in the tree, or null in a scene without a ship.
var _manager: ResearchUpgradeManager = null
## The research desk the manager spends through.
var _research: ResearchSystem = null
## The hull whose levers the panel takes while it is open.
var _ship: Node = null
## True while this console is the one that locked the hull's interface input.
var _input_lock_owned: bool = false
## Last XP total the panel showed, so a gain can pulse and a spend cannot.
var _last_xp: int = -1
## A refresh is already queued for the end of the frame.
var _refresh_pending: bool = false
## True while a purchase call is on the stack; keeps one press to one level.
var _purchasing: bool = false


func _ready() -> void:
	super._ready()
	# The panel is opened by its own key (`U`, handled by the screen) and by
	# other panels that hand the pilot over - the equipment panel's
	# "РЈР›РЈР§РЁР•РќРРЇ" button, for one.
	panel_id = "upgrades"
	_screen.upgrade_requested.connect(_on_upgrade_requested)
	_manager = _find_manager(get_tree().get_root())
	if _manager != null:
		_research = _manager.research_system()
		_manager.upgrade_purchased.connect(_on_upgrade_purchased)
		_manager.upgrade_refused.connect(_on_upgrade_refused)
	# The research desk already announces every spend the manager makes through it,
	# so subscribing to the manager's own `xp_spent` as well would be the same event
	# handled twice.
	if _research != null:
		_research.xp_gained.connect(_on_xp_changed)
		_research.xp_spent.connect(_on_xp_changed)
	refresh()


## The panel came up: rebuild it from the ship and take the levers away, so a key
## pressed while reading a screen cannot burn the engine behind it.
func _on_panel_opened() -> void:
	super._on_panel_opened()
	_set_flight_input_locked(true)


func _on_panel_closed() -> void:
	super._on_panel_closed()
	_set_flight_input_locked(false)


## A scene change or a freed ship must not leave the hull locked to a panel that
## no longer exists.
func _exit_tree() -> void:
	_set_flight_input_locked(false)


## Hand the levers to the panel, or give them back. Ownership is tracked so two
## consoles in one scene cannot unlock each other's lock.
func _set_flight_input_locked(locked: bool) -> void:
	if locked == _input_lock_owned:
		return
	if _ship == null or not is_instance_valid(_ship):
		_ship = _find_ship()
	if _ship == null or not is_instance_valid(_ship) \
			or not _ship.has_method("set_interface_input_locked"):
		return
	_ship.set_interface_input_locked(locked)
	_input_lock_owned = locked


## The manager this console drives, or null when the scene carries no ship.
func manager() -> ResearchUpgradeManager:
	return _manager


## The panel this console feeds.
func screen() -> UpgradesScreen:
	return _screen


## Rebuild the panel from the ship. Called on open and after every XP or level
## change; safe to call at any time.
func refresh() -> void:
	_refresh_pending = false
	_apply_refresh()


func _apply_refresh() -> void:
	if _screen == null:
		return
	if _manager == null:
		_screen.refresh_data(0, [])
		return
	var xp := _manager.get_xp()
	var animate := _last_xp >= 0 and xp > _last_xp
	_last_xp = xp
	_screen.refresh_data(xp, SNAPSHOT.build(_manager), animate)


## ------------------------------------------------------------------ purchases ---

## The panel asked for a level. One press is one `purchase()` call: the guard
## keeps a repeated signal from stacking two levels on one click.
func _on_upgrade_requested(_device_id: String, upgrade_id: String) -> void:
	if _manager == null or _purchasing:
		return
	_purchasing = true
	_manager.purchase(upgrade_id)
	_purchasing = false


func _on_upgrade_purchased(upgrade_id: String, level: int, spent: int,
		_remaining: int) -> void:
	refresh()
	_screen.notify_purchase(upgrade_id, level, spent)


func _on_upgrade_refused(_upgrade_id: String, reason: String) -> void:
	_screen.notify_refusal(reason)


## ------------------------------------------------------------------- signals ---

## XP changed. The manager emits `xp_spent` before `upgrade_purchased`; the
## deferred refresh collapses that into the one refresh the purchase already
## does, and covers XP gained or spent outside the panel.
func _on_xp_changed(_amount: int, _total: int) -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	call_deferred("_deferred_refresh")


## The queued XP refresh. A purchase already refreshed in the same frame, so the
## queued call is dropped instead of rebuilding the panel twice.
func _deferred_refresh() -> void:
	if not _refresh_pending:
		return
	_refresh_pending = false
	_apply_refresh()


## ------------------------------------------------------------------- internals ---

## The hull the panel takes its levers from, found the way the HUD finds it.
func _find_ship() -> Node:
	var ship := get_tree().get_first_node_in_group("player")
	if ship == null:
		ship = get_tree().get_first_node_in_group("ship")
	return ship


## Depth-first search for the manager. A scene without one - every ship-only
## suite - simply gets an empty panel instead of an error.
func _find_manager(node: Node) -> ResearchUpgradeManager:
	if node is ResearchUpgradeManager:
		return node
	for child in node.get_children():
		var found := _find_manager(child)
		if found != null:
			return found
	return null