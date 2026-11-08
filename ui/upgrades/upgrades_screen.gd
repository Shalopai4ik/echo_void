class_name UpgradesScreen
extends InterfaceScreen

## Presentation-only equipment upgrade panel.
##
## Every value it shows comes from an `UpgradeDevice` / `UpgradeVisual` snapshot.
## In the flight scene that snapshot is built by `UpgradesConsole` from
## `ResearchUpgradeManager` and the mounted devices; when the panel runs alone
## (`UpgradesPreview.tscn`) it builds a demonstration snapshot instead. The panel
## itself reads no mounted `ShipComponent`, no `ResearchSystem` and no manager:
## it emits `upgrade_requested` and stops there, and the console owns the
## purchase call. That is why the screen can be tested without a ship.
##
## What it does:
##   1. opens and closes without touching the game clock or the flight model;
##   2. lists every device and switches between them;
##   3. shows each path's current and next characteristic and its XP price;
##   4. re-derives the availability of every path when the XP total changes, so
##      the badge, the cards, the rows and the action button stay in agreement;
##   5. reports a purchase or a refusal in the footer and pulses the path that
##      changed.
##
## What it deliberately does not do: no purchase, no XP spending, no saving.

## A device card was chosen.
signal device_selected(device_id: String)
## An upgrade path was chosen inside the selected device.
signal upgrade_selected(device_id: String, upgrade_id: String)
## The pilot pressed the action button while the path was affordable. Nothing
## is bought here: `UpgradesConsole` turns it into a manager purchase.
signal upgrade_requested(device_id: String, upgrade_id: String)

const DEVICE_CARD_SCENE := preload("res://scenes/ui/components/UpgradeDeviceCard.tscn")
const PATH_ROW_SCENE := preload("res://scenes/ui/components/UpgradePathRow.tscn")
const DEMO_DATA := preload("res://ui/upgrades/upgrades_demo_data.gd")

## How many research XP the demonstration control awards.
const DEMO_XP_GAIN := 150

const NOTICE_NEUTRAL := Color(0.48, 0.68, 0.73, 1.0)
const NOTICE_OK := Color(0.46, 0.95, 0.88, 1.0)
const NOTICE_LOCK := Color(1.0, 0.7, 0.3, 1.0)
const LIVE_HINT := "[ESC] ЗАКРЫТЬ  •  [U] ОТКРЫТЬ/ЗАКРЫТЬ"
const DEMO_HINT := "[ESC] ЗАКРЫТЬ  •  [U] ОТКРЫТЬ/ЗАКРЫТЬ  •  ДЕМО-ДАННЫЕ"

## Open the panel as soon as it enters the tree.
@export var start_open: bool = true
## Show the demonstration control that previews the XP gain highlight.
@export var demo_controls: bool = true
## Build the demonstration catalogue on entry. Turned off in the flight scene,
## where `UpgradesConsole` feeds the live snapshot instead.
@export var load_demo_data: bool = true

@onready var _safe_area: MarginContainer = %SafeArea
@onready var _badge: ResearchXpBadge = %XpBadge
@onready var _device_count: Label = %DeviceCount
@onready var _device_list: VBoxContainer = %DeviceList
@onready var _empty: Label = %Empty
@onready var _detail_content: VBoxContainer = %DetailContent
@onready var _placeholder: Label = %Placeholder
@onready var _icon: Label = %DeviceIcon
@onready var _name: Label = %DeviceName
@onready var _role: Label = %DeviceRole
@onready var _device_level: Label = %DeviceLevel
@onready var _description: Label = %Description
@onready var _stats: GridContainer = %Stats
@onready var _path_caption: Label = %PathCaption
@onready var _path_list: VBoxContainer = %PathList
@onready var _selected_info: Label = %SelectedInfo
@onready var _action: Button = %Action
@onready var _demo_xp: Button = %DemoXp
@onready var _hint: Label = %Hint
@onready var _close: Button = %Close

var _devices: Array[UpgradeDevice] = []
var _cards: Dictionary = {}
var _rows: Dictionary = {}
var _selected_device: String = ""
var _selected_upgrade: String = ""
var _xp: int = 0
var _notice: Tween


func _ready() -> void:
	super._ready()
	_close.pressed.connect(close)
	_action.pressed.connect(_on_action_pressed)
	_demo_xp.pressed.connect(_on_demo_xp_pressed)
	_demo_xp.visible = demo_controls and load_demo_data
	_hint.text = DEMO_HINT if load_demo_data else LIVE_HINT
	get_viewport().size_changed.connect(_apply_safe_insets)
	_apply_safe_insets()
	if load_demo_data:
		set_data(DEMO_DATA.xp_total(), DEMO_DATA.devices())
	else:
		set_data(0, [])
	if start_open:
		open()
	else:
		close()


## ------------------------------------------------------------------ opening ---
##
## `open()`, `close()`, `toggle()` and `is_open()` live in `InterfaceScreen`:
## one place decides what "a panel is open" means for the whole game - the
## modal group, the world pause, Escape, and one panel at a time.


## The panel owns two keys and nothing else: the toggle opens and closes it, and
## Escape closes it while it is open. Neither key is a ship control.
##
## Escape and the one-panel-at-a-time rule live in `InterfaceScreen`; this
## panel adds its own key and the scanner's, which must not reach the ship
## while the pilot is reading.
func _input(event: InputEvent) -> void:
	super._input(event)
	if event.is_action_pressed("toggle_upgrades"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	# `R` is the scanner's key as well, and a sweep started behind the panel would
	# spend reactor charge on a screen the pilot is reading. Consuming the event
	# keeps it away from `ShipScanner._unhandled_input`; the HUD polls the same
	# action and stands down through the modal group.
	if visible and event.is_action_pressed("scan"):
		get_viewport().set_input_as_handled()


## ------------------------------------------------------------------- content ---

## Replace the whole panel content. A controller calls this with the manager's
## snapshot instead of the demonstration table. With `preserve_selection` the
## device and path the pilot was looking at stay selected when they still exist,
## so a purchase does not jump the panel back to the first card.
func set_data(xp: int, devices: Array[UpgradeDevice], preserve_selection: bool = false,
		animate_xp: bool = false) -> void:
	var keep_device := _selected_device if preserve_selection else ""
	var keep_upgrade := _selected_upgrade if preserve_selection else ""
	_xp = maxi(xp, 0)
	_devices = devices
	_badge.set_value(_xp, animate_xp)
	_apply_states()
	_rebuild_cards()
	_device_count.text = "УСТРОЙСТВА КОРАБЛЯ / %02d" % _devices.size()
	_empty.visible = _devices.is_empty()
	_selected_device = ""
	_selected_upgrade = ""
	_rows.clear()
	if _devices.is_empty():
		_show_placeholder()
		return
	var target := _find_device(keep_device)
	if target == null:
		target = _devices[0]
	select_device(target.id)
	if keep_upgrade.is_empty() or current_device() == null:
		return
	if current_device().find_upgrade(keep_upgrade) != null:
		select_upgrade(keep_upgrade)


## Replace the content of a live panel, keeping the pilot's selection.
func refresh_data(xp: int, devices: Array[UpgradeDevice], animate_xp: bool = false) -> void:
	set_data(xp, devices, true, animate_xp)


## A purchase went through: pulse the path that changed, the action button and
## the XP badge, and state it in the footer.
func notify_purchase(upgrade_id: String, level: int, spent: int) -> void:
	var row := _rows.get(upgrade_id) as UpgradePathRow
	if row != null:
		row.flash()
	_flash_action()
	_badge.flash_spend(spent)
	_show_notice("УЛУЧШЕНО ДО УР. %d · −%d XP" % [level, spent], NOTICE_OK)


## A purchase was refused: say why in the footer and re-assert the button state.
func notify_refusal(reason: String) -> void:
	_refresh_action()
	_show_notice(_refusal_text(reason), NOTICE_LOCK)


## The device the detail panel shows, or null.
func current_device() -> UpgradeDevice:
	return _find_device(_selected_device)


## The path the action button would buy, or null.
func current_upgrade() -> UpgradeVisual:
	var device := current_device()
	if device == null:
		return null
	return device.find_upgrade(_selected_upgrade)


func xp() -> int:
	return _xp


## Show a new XP total. A gain pulses the badge and re-derives which paths are
## affordable; nothing is spent.
func set_xp(value: int) -> void:
	var next := maxi(value, 0)
	var gained := next > _xp
	_xp = next
	_badge.set_value(_xp, gained)
	_apply_states()
	_refresh()


## Award demonstration XP. Kept as its own verb so the panel has no spending path.
func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	set_xp(_xp + amount)


func select_device(device_id: String) -> void:
	var device := _find_device(device_id)
	if device == null:
		return
	_selected_device = device_id
	for id in _cards:
		(_cards[id] as UpgradeDeviceCard).set_selected(id == device_id)
	_show_device(device)
	var first := _first_path(device)
	if first != null:
		select_upgrade(first.id)
	else:
		_selected_upgrade = ""
		_selected_info.text = ""
		_refresh_action()
	device_selected.emit(device_id)


func select_upgrade(upgrade_id: String) -> void:
	var device := current_device()
	if device == null:
		return
	var upgrade := device.find_upgrade(upgrade_id)
	if upgrade == null:
		return
	_selected_upgrade = upgrade_id
	for id in _rows:
		(_rows[id] as UpgradePathRow).set_selected(id == upgrade_id)
	_selected_info.text = _selected_info_text(upgrade)
	_refresh_action()
	upgrade_selected.emit(_selected_device, upgrade_id)


## ----------------------------------------------------------------- internals ---

## Re-derive every path's availability from the XP total shown.
func _apply_states() -> void:
	for device in _devices:
		for upgrade in device.upgrades:
			if upgrade.level >= upgrade.max_level:
				upgrade.state = UpgradeVisual.State.MAXED
			elif upgrade.cost_xp > _xp:
				upgrade.state = UpgradeVisual.State.INSUFFICIENT_XP
			else:
				upgrade.state = UpgradeVisual.State.AVAILABLE


func _rebuild_cards() -> void:
	_cards.clear()
	for child in _device_list.get_children():
		_device_list.remove_child(child)
		child.queue_free()
	for device in _devices:
		var card := DEVICE_CARD_SCENE.instantiate() as UpgradeDeviceCard
		_device_list.add_child(card)
		card.configure(device)
		card.selected.connect(select_device)
		_cards[device.id] = card


## Re-paint every card and the rows of the selected device after the XP total
## moved. The selection is re-applied because a card resets its own style when it
## is configured.
func _refresh() -> void:
	for device in _devices:
		var card := _cards.get(device.id) as UpgradeDeviceCard
		if card == null:
			continue
		card.configure(device)
		card.set_selected(device.id == _selected_device)
	var device := current_device()
	if device == null:
		return
	for upgrade in device.upgrades:
		var row := _rows.get(upgrade.id) as UpgradePathRow
		if row == null:
			continue
		row.configure(upgrade)
		row.set_selected(upgrade.id == _selected_upgrade)
	var upgrade := current_upgrade()
	if upgrade != null:
		_selected_info.text = _selected_info_text(upgrade)
	_refresh_action()


func _show_device(device: UpgradeDevice) -> void:
	_detail_content.visible = true
	_placeholder.visible = false
	_icon.text = device.glyph
	_name.text = device.title
	_role.text = device.role
	_device_level.text = "%s · %s" % [device.level_text(), device.state_text()]
	_description.text = device.description
	_rebuild_stats(device)
	_rebuild_rows(device)


func _show_placeholder() -> void:
	_detail_content.visible = false
	_placeholder.visible = true
	_selected_info.text = ""
	_refresh_action()


## The device's current characteristics: one caption/value pair per path.
func _rebuild_stats(device: UpgradeDevice) -> void:
	for child in _stats.get_children():
		_stats.remove_child(child)
		child.queue_free()
	for upgrade in device.upgrades:
		var caption := Label.new()
		caption.text = upgrade.attribute_label
		caption.add_theme_font_size_override("font_size", 8)
		caption.add_theme_color_override("font_color", Color(0.48, 0.68, 0.73, 1.0))
		_stats.add_child(caption)
		var value := Label.new()
		value.text = upgrade.current_text
		value.add_theme_font_size_override("font_size", 10)
		value.add_theme_color_override("font_color", Color(0.82, 0.95, 0.98, 1.0))
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_stats.add_child(value)


func _rebuild_rows(device: UpgradeDevice) -> void:
	_rows.clear()
	for child in _path_list.get_children():
		_path_list.remove_child(child)
		child.queue_free()
	for upgrade in device.upgrades:
		var row := PATH_ROW_SCENE.instantiate() as UpgradePathRow
		_path_list.add_child(row)
		row.configure(upgrade)
		row.selected.connect(select_upgrade)
		_rows[upgrade.id] = row
	_path_caption.text = "ВЕТКИ УЛУЧШЕНИЙ / %02d" % device.upgrades.size()


## What the selected path does, and what the next level would change.
func _selected_info_text(upgrade: UpgradeVisual) -> String:
	var lines := PackedStringArray()
	lines.append(upgrade.description)
	if upgrade.is_maxed():
		lines.append("ВЕТКА ЗАВЕРШЕНА · %s" % upgrade.current_text)
	else:
		lines.append("СЛЕДУЮЩИЙ УРОВЕНЬ · %s · %s" % [upgrade.cost_text(), upgrade.next_text])
	return "\n".join(lines)


func _refresh_action() -> void:
	var upgrade := current_upgrade()
	if upgrade == null:
		_action.disabled = true
		_action.text = "ВЫБЕРИТЕ УСТРОЙСТВО"
		return
	match upgrade.state:
		UpgradeVisual.State.AVAILABLE:
			_action.disabled = false
			_action.text = "УЛУЧШИТЬ ЗА %04d XP" % upgrade.cost_xp
		UpgradeVisual.State.INSUFFICIENT_XP:
			_action.disabled = true
			_action.text = "НЕДОСТАТОЧНО RESEARCH XP"
		_:
			_action.disabled = true
			_action.text = "МАКСИМАЛЬНЫЙ УРОВЕНЬ"


## The path a device should open on: the first one the pilot can pay for, or the
## first one at all so the panel never shows an empty detail.
func _first_path(device: UpgradeDevice) -> UpgradeVisual:
	for upgrade in device.upgrades:
		if upgrade.is_available():
			return upgrade
	if device.upgrades.is_empty():
		return null
	return device.upgrades[0]


func _find_device(device_id: String) -> UpgradeDevice:
	for device in _devices:
		if device.id == device_id:
			return device
	return null


## The button only reports the order. Spending is a later controller's job.
func _on_action_pressed() -> void:
	var upgrade := current_upgrade()
	if upgrade == null or upgrade.state != UpgradeVisual.State.AVAILABLE:
		return
	upgrade_requested.emit(_selected_device, _selected_upgrade)


func _on_demo_xp_pressed() -> void:
	add_xp(DEMO_XP_GAIN)


## Short feedback in the footer's hint line. The neutral hint comes back after a
## moment, so the panel never keeps stale news on screen.
func _show_notice(text: String, color: Color) -> void:
	if _notice != null and _notice.is_valid():
		_notice.kill()
	_hint.text = text
	_hint.add_theme_color_override("font_color", color)
	_notice = create_tween()
	_notice.tween_interval(1.6)
	_notice.tween_callback(_end_notice)


func _end_notice() -> void:
	_hint.text = DEMO_HINT if load_demo_data else LIVE_HINT
	_hint.add_theme_color_override("font_color", NOTICE_NEUTRAL)


## Pulse the action button after a purchase - a second, wordless confirmation.
func _flash_action() -> void:
	_action.modulate = Color(0.72, 1.0, 0.92, 1.0)
	var tween := create_tween()
	tween.tween_property(_action, "modulate", Color.WHITE, 0.5)


## The refusal reason the manager reports, in the panel's own words.
func _refusal_text(reason: String) -> String:
	match reason:
		"insufficient_xp":
			return "ОТКАЗ · НЕДОСТАТОЧНО RESEARCH XP"
		"max_level":
			return "ОТКАЗ · УСТРОЙСТВО УЖЕ НА ПРЕДЕЛЕ"
		"device_not_found":
			return "ОТКАЗ · УСТРОЙСТВО НЕ УСТАНОВЛЕНО"
		"wrong_device_type":
			return "ОТКАЗ · НЕСОВМЕСТИМОЕ УСТРОЙСТВО"
		"no_research_system":
			return "ОТКАЗ · ИССЛЕДОВАТЕЛЬСКИЙ СТОЛ НЕ ПОДКЛЮЧЁН"
	return "ОТКАЗ · %s" % reason.to_upper()


func _apply_safe_insets() -> void:
	var inset := safe_inset()
	_safe_area.add_theme_constant_override("margin_left", roundi(inset))
	_safe_area.add_theme_constant_override("margin_right", roundi(inset))
	_safe_area.add_theme_constant_override("margin_top", roundi(inset * 0.75))
	_safe_area.add_theme_constant_override("margin_bottom", roundi(inset * 0.75))