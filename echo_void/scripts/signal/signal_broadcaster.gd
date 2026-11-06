extends Node
class_name SignalBroadcaster

const SignalMessage := preload("res://scripts/signal/signal_message.gd")

## The one place every active signal lives while it burns.
##
## Signal lights (and anything else added later) register a SignalMessage here
## when they start and drop out when they finish. Anything in the world - a
## creature, a hazard, a future AI - asks "what signals reach me?" and decides
## for itself. This file knows nothing about threats, AI, or the ship: it is
## just a bounded, time-stamped bag of broadcasts that ticks down by itself.
##
## Designed so a later upgrade can replace this node with a more sophisticated
## propagation model (jammers, nebula attenuation, line of sight) without
## changing any listener: the query API stays the same.

## A signal that started but has not expired yet. Keyed by source_id so a
## broadcaster can replace its own previous message instead of stacking.
var active: Dictionary = {}

## Emitted whenever a signal enters or leaves the air. Carries the message
## dictionary; `gone` tells listeners whether it finished or was cut short.
signal signal_onair(msg: Dictionary, gone: bool)
## Emitted when the broadcaster itself is asked to clear everything (scenario
## reset, new save).
signal signals_cleared()

## How many signals are currently audible. Pure question, costs nothing.
func count() -> int:
	return active.size()

## Put a signal on the air, replacing any earlier signal from the same source.
## Returns the stored message (with expires_at filled in) so the owner can keep
## a reference and ask when it ends.
func broadcast(msg: SignalMessage) -> SignalMessage:
	if msg == null:
		return null
	var now := ShipSystemEvent.now()
	if msg.at <= 0.0:
		msg.at = now
	if msg.expires_at <= msg.at and msg.expires_at < INF:
		# duration was already baked into expires_at by the constructor; nothing
		# to do here.
		pass
	var stored := msg.duplicate()
	active[msg.source_id] = stored
	signal_onair.emit(stored.to_dict(), false)
	return stored

## Take one source's signal off the air early. Returns true when something was
## actually removed.
func retract(source_id: String) -> bool:
	if not active.has(source_id):
		return false
	var msg := active[source_id] as SignalMessage
	if msg == null:
		return false
	active.erase(source_id)
	signal_onair.emit(msg.to_dict(), true)
	return true

## Clear every signal. Used by scenario resets and tests, not by normal play.
func clear_all() -> void:
	if active.is_empty():
		return
	active.clear()
	signals_cleared.emit()

## Tick once per physics step. Removes expired signals and reports them gone.
## Costs one dictionary walk per active signal - cheap because signals are rare
## and short-lived, never every object every frame.
func tick(delta: float) -> void:
	var now := ShipSystemEvent.now()
	var gone: Array = []
	for id in active.keys():
		var msg := active[id] as SignalMessage
		if msg == null:
			continue
		if msg.is_expired(now):
			active.erase(id)
			gone.append(msg.to_dict())
	for msg in gone:
		signal_onair.emit(msg, true)

## Every signal currently on the air, as dictionaries. A copy: callers cannot
## corrupt the broadcaster's state by editing what comes back.
func messages() -> Array:
	var out: Array = []
	for id in active.keys():
		var msg := active[id] as SignalMessage
		if msg != null:
			out.append(msg.to_dict())
	return out

## All signals whose disc covers this point, nearest first, each with the
## strength they read there. This is the query a creature (or anything else)
## makes to decide whether to react. Returns an empty array in silence.
func signals_near(point: Vector2) -> Array:
	var out: Array = []
	var now := ShipSystemEvent.now()
	for id in active.keys():
		var msg := active[id] as SignalMessage
		if msg == null or msg.is_expired(now):
			continue
		var strength := msg.strength_at(point)
		if strength <= 0.0:
			continue
		out.append({
			"source_id": msg.source_id,
			"kind": msg.kind,
			"position": msg.position,
			"radius_px": msg.radius_px,
			"intensity": msg.intensity,
			"strength": strength,
			"distance": point.distance_to(msg.position),
			"at": msg.at,
			"expires_at": msg.expires_at,
		})
	out.sort_custom(func(a, b):
		return float(a["distance"]) < float(b["distance"])
	)
	return out

## The single strongest signal reaching this point, or an empty dictionary in
## silence. The quick "should I react at all?" question.
func strongest_at(point: Vector2) -> Dictionary:
	var near := signals_near(point)
	if near.is_empty():
		return {}
	return near[0]

## Is anything audible right now? Pure question, cheaper than signals_near().
func any_signal() -> bool:
	var now := ShipSystemEvent.now()
	for id in active.keys():
		var msg := active[id] as SignalMessage
		if msg != null and not msg.is_expired(now):
			return true
	return false

## Clean up expired entries without waiting for the next tick. Mostly for
## tests that want a deterministic air.
func sweep_expired() -> int:
	var now := ShipSystemEvent.now()
	var removed := 0
	for id in active.keys().duplicate():
		var msg := active[id] as SignalMessage
		if msg == null:
			continue
		if msg.is_expired(now):
			active.erase(id)
			removed += 1
	return removed
