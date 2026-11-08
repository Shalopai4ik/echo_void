extends Resource
class_name ResearchUpgrade

## One level of one equipment upgrade, as data.
##
## An upgrade is identified by `upgrade_id` (a dot path like "scanner.range")
## and `level` (1-based). Levels must be bought in order; the manager never
## skips. `device_id` is the component_id the upgrade is installed on and
## `device_type` is its class name, used to confirm the right device before
## writing properties. `attribute` is the property path on the device.
##
## `modifier_type` decides how the per-level `value` combines with the
## device's base value:
##   "multiply" - base * value^level
##   "add"      - base + value * level
##   "set"      - value (replaces base entirely at this level)
##
## `cost_xp` is the research XP price of this level. `max_level` caps the
## whole path.
##
## The base value is snapshotted from the device the first time this upgrade
## is applied and stored in `base_value`, so later levels always compute from
## the ship's real starting numbers.

@export_group("Identity")
## Stable dot-path id, e.g. "scanner.range". Used in save data and signals.
@export var upgrade_id: String = ""
## Human-readable name for a panel or log.
@export var display_name: String = "Upgrade"
## Human-readable description.
@export var description: String = ""

@export_group("Target")
## The component_id this upgrade is installed on, e.g. "scanner".
@export var device_id: String = ""
## The component class name, e.g. "ShipScanner". The manager checks this
## before writing to a device.
@export var device_type: String = ""
## The property path on the device, e.g. "range_multiplier". Must be a direct
## exported property the device has.
@export var attribute: String = ""

@export_group("Level")
## This entry's level, 1-based.
@export_range(1, 100, 1) var level: int = 1
## The highest level this upgrade path reaches. The manager refuses beyond it.
@export_range(1, 100, 1) var max_level: int = 1

@export_group("Effect")
## "multiply", "add" or "set".
@export_enum("multiply", "add", "set") var modifier_type: String = "multiply"
## Per-level multiplier / addend / absolute value.
@export_range(-1000.0, 1000.0, 0.01) var value: float = 1.0

@export_group("Cost")
## Research XP cost to buy this level.
@export_range(0, 1000000, 10) var cost_xp: int = 50

## Snapshot of the device's attribute value before any upgrade was applied.
## Set by `snapshot_base()` and persisted by the manager.
var base_value: float = 0.0
## True once `base_value` has been snapshotted.
var base_snapshotted: bool = false

## Record the device's current attribute value as the base for this upgrade.
## Safe to call multiple times - only the first call records.
func snapshot_base(device: Object) -> void:
	if base_snapshotted:
		return
	if device != null:
		base_value = float(device.get(attribute))
	base_snapshotted = true

## Apply this upgrade's level to `device`. Computes the final value from
## `base_value` and writes it to the device's attribute.
func apply_to(device: Object) -> void:
	if device == null:
		return
	var target: float
	match modifier_type:
		"multiply":
			target = base_value * pow(value, level)
		"add":
			target = base_value + value * level
		"set":
			target = value
		_:
			target = base_value
	device.set(attribute, target)

## Reset the snapshot so the next `snapshot_base()` re-reads from the device.
func reset_base() -> void:
	base_snapshotted = false
	base_value = 0.0