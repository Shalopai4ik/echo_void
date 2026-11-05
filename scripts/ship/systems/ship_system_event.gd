extends RefCounted
class_name ShipSystemEvent

## One message on the ship's internal bus.
##
## The brief asks for events to travel between the systems, and the failure mode
## with events is always the same: every listener ends up holding direct references
## to every producer, and the graph becomes the architecture. So there is one value
## object instead, and exactly two ways for it to exist - the hub builds one from a
## component signal, or a device asks the hub to publish one. Everything else is a
## listener.
##
## It is a `RefCounted` with plain fields rather than a `Node` or a `Resource`: no
## identity, no tree, no editor, nothing to leak between frames. `data` is where an
## event that is not one of the standard kinds puts its own vocabulary; the standard
## fields stay the same for every kind so a panel can print any event without a
## `match` on the producer.
##
## Nothing in the ship is allowed to drive physics from an event handler. The event
## stream describes what already happened; a handler that wants the hull to move
## goes through `ShipController`, never around it.

## What happened. The first seven are raised by the hub itself; `EQUIPMENT` and
## `CUSTOM` are the two doors a device uses to say something the hub cannot know.
enum Kind {
	STATE_CHANGED,
	POWER_CHANGED,
	DAMAGE_TAKEN,
	REPAIRED,
	ENABLED,
	DISABLED,
	IMPACT,
	EQUIPMENT,
	CUSTOM,
	## The reserve fell to or below the low line. `amount` is the ratio.
	ENERGY_LOW,
	## The reserve hit zero and the bus is dark.
	ENERGY_DEPLETED,
	## The reserve climbed back above the restart line and the bus is live again.
	ENERGY_RESTORED,
}

## The kind, and the id of the component it is about. An empty id means the ship
## itself - a hull hit, or a hull-level state change.
var kind: int = Kind.CUSTOM
var component_id := ""

## For `STATE_CHANGED`: the state before and after. -1 means "not a state event",
## which is the honest value rather than a plausible-looking `NOMINAL`.
var previous_state := -1
var state := -1

## The magnitude of the event where one exists: integrity lost or restored, the
## power ratio granted, the closing speed of an impact.
var amount := 0.0

## The producer's own vocabulary. Never assumed to hold a particular key by the
## hub, never mutated by a listener.
var data := {}

## Physics time, not wall time - the same clock `ShipController` keeps its contact
## cooldowns on, so a log line and a panel line can be laid against each other.
var at := 0.0


func _init(event_kind: int = Kind.CUSTOM, id: String = "") -> void:
	kind = event_kind
	component_id = id
	at = now()


## Physics seconds since the tree started. Static because an event created in a
## test before the tree exists still deserves a timestamp.
static func now() -> float:
	var ticks := float(Engine.physics_ticks_per_second)
	if ticks <= 0.0:
		return 0.0
	return float(Engine.get_physics_frames()) / ticks


static func state_changed(id: String, previous: int, current: int) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.STATE_CHANGED, id)
	event.previous_state = previous
	event.state = current
	return event


static func power_changed(id: String, ratio: float) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.POWER_CHANGED, id)
	event.amount = ratio
	return event


## The reserve crossed its low line. The ratio is in `amount`; the level and the tank
## are in `data` so a listener that only has the event can still print "18 / 120".
static func energy_low(ratio: float, charge: float, capacity: float) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.ENERGY_LOW, "")
	event.amount = ratio
	event.data = {"ratio": ratio, "charge": charge, "capacity": capacity}
	return event


## The reserve is empty. Nobody predicted it: by the time this is dispatched the
## devices are already at a grant of zero.
static func energy_depleted(charge: float, capacity: float) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.ENERGY_DEPLETED, "")
	event.amount = charge
	event.data = {"charge": charge, "capacity": capacity}
	return event


## The reserve is back above the restart line.
static func energy_restored(ratio: float, charge: float,
		capacity: float) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.ENERGY_RESTORED, "")
	event.amount = ratio
	event.data = {"ratio": ratio, "charge": charge, "capacity": capacity}
	return event


static func damaged(id: String, amount: float, integrity: float,
		source: String = "") -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.DAMAGE_TAKEN, id)
	event.amount = amount
	event.data = {"integrity": integrity, "source": source}
	return event


static func repaired(id: String, amount: float, integrity: float,
		source: String = "") -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.REPAIRED, id)
	event.amount = amount
	event.data = {"integrity": integrity, "source": source}
	return event


static func toggled(id: String, enabled: bool) -> ShipSystemEvent:
	return ShipSystemEvent.new(Kind.ENABLED if enabled else Kind.DISABLED, id)


## A contact the world made with the hull. `severity` is the band the ship's own
## collision report already decided on - LIGHT, MEDIUM or HEAVY - and the closing
## speed is kept separate from `amount` so a listener that only has the event can
## still tell the two apart.
static func impact(severity: String, closing_speed: float,
		details: Dictionary = {}) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.IMPACT, "")
	event.amount = closing_speed
	event.data = details.duplicate(true)
	event.data["severity"] = severity
	event.data["closing_speed"] = closing_speed
	return event


## Something a device wants the rest of the ship to know, in its own words.
static func equipment(id: String, topic: String,
		details: Dictionary = {}) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.EQUIPMENT, id)
	event.data = details.duplicate(true)
	event.data["topic"] = topic
	return event


static func custom(id: String, topic: String,
		details: Dictionary = {}) -> ShipSystemEvent:
	var event := ShipSystemEvent.new(Kind.CUSTOM, id)
	event.data = details.duplicate(true)
	event.data["topic"] = topic
	return event


## The kind as text, for the panel and for a test failure message that has to say
## what it actually received.
func kind_name() -> String:
	var names := Kind.keys()
	if kind < 0 or kind >= names.size():
		return "UNKNOWN"
	return String(names[kind])


## One line, in the shape the debug panel prints its other lines.
func describe() -> String:
	var who := component_id if component_id != "" else "ship"
	var text := "%s %s" % [kind_name(), who]
	if kind == Kind.STATE_CHANGED:
		text += " %s -> %s" % [ShipSystemState.name_of(previous_state),
			ShipSystemState.name_of(state)]
	elif absf(amount) > 0.0:
		text += " %.2f" % amount
	if data.has("topic"):
		text += " \"%s\"" % String(data.topic)
	elif data.has("severity"):
		text += " %s" % String(data.severity)
	return text


## A plain copy, for a log or a test that wants to keep an event after the frame
## it was raised in. The `Node` an impact points at is deliberately not included:
## it may already be freed, and everything a reader needs about it is in `data`.
func to_dictionary() -> Dictionary:
	return {
		"kind": kind,
		"kind_name": kind_name(),
		"component": component_id,
		"previous_state": previous_state,
		"state": state,
		"amount": amount,
		"data": data.duplicate(true),
		"at": at,
	}