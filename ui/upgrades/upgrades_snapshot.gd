class_name UpgradesSnapshot
extends RefCounted

## Builds the panel's display snapshots from the live ship.
##
## This is the seam the presentation-only panel deliberately does not cross: it
## reads `ResearchUpgradeManager` for levels, prices and the mounted devices, and
## the catalogue resource for what each level multiplies. Nothing here spends,
## saves or changes a device - `UpgradesConsole` owns the purchase call.
##
## A device is listed only when the hull actually carries it, so the panel can
## never offer a level for a device that is not mounted. Prices and maximum
## levels come from `ResearchUpgradeProfile`, never from a second table: tuning
## a cost is an edit to `assets/research/research_upgrade_profile.tres` alone.

const PRESENTATION := preload("res://ui/upgrades/upgrades_presentation.gd")


## One `UpgradeDevice` per mounted device that the catalogue upgrades.
static func build(manager: ResearchUpgradeManager) -> Array[UpgradeDevice]:
	var out: Array[UpgradeDevice] = []
	if manager == null or manager.profile == null:
		return out
	for device_id in _device_order(manager):
		var device := manager.device_for(device_id)
		if device == null:
			continue
		out.append(_build_device(manager, device_id, device))
	return out


## Catalogue devices first in display order, then any device the catalogue grew
## without a display entry, so a new upgrade can never disappear silently.
static func _device_order(manager: ResearchUpgradeManager) -> Array[String]:
	var ids: Array[String] = []
	for device_id in PRESENTATION.device_ids():
		if manager.profile.paths_for_device(device_id).size() > 0:
			ids.append(device_id)
	for device_id in manager.profile.device_ids():
		if not ids.has(device_id):
			ids.append(device_id)
	return ids


static func _build_device(manager: ResearchUpgradeManager, device_id: String,
		device: Object) -> UpgradeDevice:
	var meta := PRESENTATION.device(device_id)
	var out := UpgradeDevice.new()
	out.id = device_id
	out.title = str(meta.get("title", ""))
	if out.title.is_empty() and device.has_method("display_name"):
		out.title = str(device.call("display_name")).to_upper()
	out.role = str(meta.get("role", "SHIP COMPONENT"))
	out.glyph = str(meta.get("glyph", "◇"))
	out.description = str(meta.get("description", ""))
	for upgrade_id in manager.profile.paths_for_device(device_id):
		var visual := _build_path(manager, upgrade_id, device)
		if visual != null:
			out.upgrades.append(visual)
	return out


static func _build_path(manager: ResearchUpgradeManager, upgrade_id: String,
		device: Object) -> UpgradeVisual:
	var entries := manager.profile.path(upgrade_id)
	if entries.is_empty():
		return null
	var meta := PRESENTATION.path(upgrade_id)
	var level := manager.get_level(upgrade_id)
	var next_entry := manager.profile.find(upgrade_id, level + 1)
	var current := _read_value(device, entries[0].attribute, str(meta.get("read", "")))
	var decimals := int(meta.get("decimals", 0))
	var unit := str(meta.get("unit", ""))

	var out := UpgradeVisual.new()
	out.id = upgrade_id
	out.title = str(meta.get("title", entries[0].display_name))
	out.description = str(meta.get("description", entries[0].description))
	out.attribute_label = str(meta.get("caption", entries[0].display_name))
	out.level = level
	out.max_level = manager.profile.max_level_for(upgrade_id)
	out.cost_xp = maxi(manager.next_cost(upgrade_id), 0)
	out.current_text = UpgradeVisual.format_value(current, decimals, unit)
	out.next_text = UpgradeVisual.format_value(_next_value(current, next_entry),
		decimals, unit)
	return out


## The characteristic as the pilot experiences it. A device getter wins because
## it folds in the profile and the hull's condition; otherwise the upgrade's own
## attribute is read raw.
static func _read_value(device: Object, attribute: String, read_method: String) -> float:
	if not read_method.is_empty() and device.has_method(read_method):
		return float(device.call(read_method))
	if attribute.is_empty():
		return 0.0
	return float(device.get(attribute))


## The value the next level would show. `apply_to()` multiplies the device's
## base by the per-level factor, and the live value is that base times the
## factors already bought, so the next readout is simply the current one times
## (or plus) the next entry's own value.
static func _next_value(current: float, entry: ResearchUpgrade) -> float:
	if entry == null:
		return current
	match entry.modifier_type:
		"multiply":
			return current * entry.value
		"add":
			return current + entry.value
		"set":
			return entry.value
	return current