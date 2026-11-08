class_name UpgradeVisual
extends RefCounted

## Presentation-only snapshot of one upgrade path: one attribute of one device,
## its bought level and the price of the next level.
##
## This mirrors no gameplay resource. The catalogue in
## `assets/research/research_upgrade_profile.tres` is the source the demo data
## copies its ladder from, and stage 7 will map `ResearchUpgradeManager` plus a
## device `status()` dictionary onto this model. Nothing here reads the manager,
## the research desk or a mounted device.

enum State {
	AVAILABLE,        ## the next level exists and the shown XP total pays for it
	INSUFFICIENT_XP,  ## the next level exists but costs more than the pilot has
	MAXED,            ## the catalogue has no next level for this path
}

## Stable dot-path id, e.g. "scanner.range".
var id: String = ""
## Human-readable path name, e.g. "ДАЛЬНОСТЬ ОБЗОРА".
var title: String = ""
## One line of what the path changes.
var description: String = ""
## The characteristic the path moves, e.g. "РАДИУС ОБЗОРА".
var attribute_label: String = ""
## Bought level, 0 when nothing was bought yet.
var level: int = 0
## Highest level declared by the catalogue.
var max_level: int = 1
## Current value, formatted for display, e.g. "1100 px".
var current_text: String = ""
## Value after the next level, formatted for display, e.g. "1375 px".
var next_text: String = ""
## Research XP price of the next level; 0 when the path is maxed.
var cost_xp: int = 0
## One of `State`.
var state: int = State.MAXED


func is_available() -> bool:
	return state == State.AVAILABLE


func is_maxed() -> bool:
	return state == State.MAXED


func level_text() -> String:
	return "УР. %d/%d" % [level, max_level]


## Current value on the left, the value after the next level on the right.
func change_text() -> String:
	if is_maxed():
		return "%s · ПРЕДЕЛ" % current_text
	return "%s → %s" % [current_text, next_text]


func cost_text() -> String:
	if is_maxed():
		return "—"
	return "%04d XP" % cost_xp


func status_text() -> String:
	match state:
		State.AVAILABLE:
			return "ДОСТУПНО"
		State.INSUFFICIENT_XP:
			return "НЕДОСТАТОЧНО XP"
		_:
			return "МАКСИМУМ"


## Format a characteristic the way the panel prints it: "1100 px", "3.0 с",
## "×1.20". One implementation for the demonstration table and the live
## snapshot, so a value never reads two different ways.
static func format_value(value: float, decimals: int, unit: String) -> String:
	if decimals <= 0:
		return "%d %s" % [roundi(value), unit]
	var number := ("%." + str(decimals) + "f") % value
	if unit == "×":
		return "×" + number
	if unit.is_empty():
		return number
	return number + " " + unit