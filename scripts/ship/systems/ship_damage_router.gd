extends RefCounted
class_name ShipDamageRouter

## Where the world's arithmetic becomes the ship's.
##
## The flight model already does the hard part: `ship_collision_detected` hands over
## what was hit, from which direction, and how fast the gap was closing, and it has
## already sorted the contact into one of three bands against `ShipWorldParameters`.
## What it must not do is decide what that costs - that is a property of the hull, not
## of the flight model - and what the hull's devices must not do is each re-derive it
## from the same dictionary. So this class is the single reading of an impact on the
## ship's side of the world:
##
##     info dictionary  ->  severity + closing speed  ->  one ShipSystemEvent
##
## and, only when the tuning resource allows it, one hull integrity loss. The switch is
## **on** as of stage 4.3: a collision that costs nothing is architecture without a
## mechanic. A scene that wants collisions to stay cosmetic turns it off in the resource
## and still receives every event.
##
## Two things are stated here rather than discovered later by a reader of the log:
##
## - the numbers are **estimates**, because Godot's 2D bodies hand out a closing speed
##   and no impulse (`ShipController` says the same in its own comment). Every report
##   carries `"estimate": true` so nothing downstream quietly upgrades a guess into a
##   measurement;
## - an impact is reported even when it costs nothing. A hull that cannot be hurt yet
##   still needs the event for audio, shake, a log line, or a scripted ambush - and a
##   listener that has to check a switch before it can hear a collision is a listener
##   that will miss one.

## The tuning resource, shared with the rest of the layer.
var parameters: ShipSystemsParameters

## The collision bands the flight model uses, when the ship has them. Optional: a
## router built outside a ship still classifies by closing speed through the default
## band edges of `ShipWorldParameters`.
var world: ShipWorldParameters

## One shared default for a router with no ship around it, so the band edges are never
## restated in this file.
static var _fallback_world: ShipWorldParameters

## The last impact, normalized for a panel or a test. The raw dictionary the flight
## model emitted may point at a body that has since been recycled, so only the parts
## that stay true are kept.
var last_impact := {}

## How many impacts this hull has reported. A count is the cheapest way for a test -
## or a debug overlay - to prove the bridge is alive without reading a log.
var impact_count := 0


func _init(params: ShipSystemsParameters = null) -> void:
	parameters = params if params != null else ShipSystemsParameters.new()


func set_parameters(params: ShipSystemsParameters) -> void:
	parameters = params if params != null else ShipSystemsParameters.new()


## Read one contact report and turn it into the ship's own event. `route_impact()`
## never mutates the event's contents afterwards and never touches integrity - the hub
## decides whether the event is also a wound, because that decision needs the health
## ledger this class does not own.
func route_impact(info: Dictionary) -> ShipSystemEvent:
	var closing := maxf(0.0, float(info.get("closing_speed", 0.0)))
	var severity := String(info.get("category", ""))
	if severity.is_empty():
		severity = severity_for(closing)
	var description: Dictionary = info.get("description", {})
	var details := {
		"severity": severity,
		"closing_speed": closing,
		"kind": String(description.get("kind", "")),
		"label": String(description.get("label", "")),
		"direction": info.get("direction", Vector2.ZERO),
		"contact_point": info.get("contact_point", Vector2.ZERO),
		"estimate": true,
	}
	impact_count += 1
	last_impact = {
		"severity": severity,
		"closing_speed": closing,
		"kind": String(details.kind),
		"label": String(details.label),
		"at": ShipSystemEvent.now(),
	}
	return ShipSystemEvent.impact(severity, closing, details)


## Which band a closing speed falls in, from the ship's own collision thresholds.
## Used only when a caller handed over a bare speed - the flight model's report
## normally already carries the band it decided on, and that answer wins.
func severity_for(closing: float) -> String:
	var bands := _bands()
	if closing >= bands.heavy_collision_threshold:
		return "HEAVY"
	if closing >= bands.medium_collision_threshold:
		return "MEDIUM"
	return "LIGHT"


## The tuning resource, or the shipping defaults for a router built outside a ship.
## Sharing one default instance rather than restating the three numbers here keeps
## `ShipWorldParameters` the only place a band edge is written down.
func _bands() -> ShipWorldParameters:
	if world != null:
		return world
	if _fallback_world == null:
		_fallback_world = ShipWorldParameters.new()
	return _fallback_world


## What a contact of this severity costs the hull, in hull points. A lookup, not a
## formula: the bands are what the flight model already decided, and the three numbers
## are the designer's per-band price for living through them.
func damage_for(severity: String) -> float:
	var p := settings()
	match severity:
		"HEAVY":
			return p.heavy_impact_damage
		"MEDIUM":
			return p.medium_impact_damage
		_:
			return p.light_impact_damage


func settings() -> ShipSystemsParameters:
	if parameters == null:
		parameters = ShipSystemsParameters.new()
	return parameters


## The panel lines: whether impacts currently cost anything, and what the last one
## was. Both are questions a reader asks in that order when the hull is losing
## integrity and nobody can say why.
func report() -> Array[String]:
	var lines: Array[String] = [
		"impacts    %d  damage %s" % [impact_count,
			"on" if settings().impact_damage_enabled else "routed only"],
	]
	if last_impact.is_empty():
		lines.append("last       none")
	else:
		lines.append("last       %s %.0f px/s  %s" % [String(last_impact.severity),
			float(last_impact.closing_speed), String(last_impact.label)])
	return lines