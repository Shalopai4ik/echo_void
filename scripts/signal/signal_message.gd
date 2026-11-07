class_name SignalMessage

## One broadcast signal - a value object, not a node.
##
## A signal light (or anything else later) hands one of these to the
## SignalBroadcaster when it starts, and the broadcaster hands copies out to
## whoever asks. Objects in the world can then decide for themselves whether the
## signal matters to them - no AI, no hard-coded threat list, just data.
##
## The message carries everything a listener needs: who sent it, where it is,
## how loud it is (intensity), how far it reaches (radius), and when it expires.
## Nothing here touches the ship, so a test or a future threat can build one by
## hand and feed it straight to the broadcaster.

## How bright the signal is. Multiplied into a listener's own perception math.
@export var intensity: float = 1.0
## Radius in pixels the signal can be heard inside. 0 means "here only".
@export var radius_px: float = 400.0
## Stable id of the broadcaster that emitted this signal - "signal_light:1" etc.
@export var source_id: String = ""
## Kind of signal, so a listener can tell a flare from a distress call later.
@export var kind: String = "signal_light"
## Position in world pixels where the signal originates.
@export var position: Vector2 = Vector2.ZERO
## Monotonic clock time the signal was sent, in seconds (ShipSystemEvent.now()).
@export var at: float = 0.0
## Monotonic clock time the signal stops being active.
@export var expires_at: float = 0.0

func _init(source_id: String = "", position: Vector2 = Vector2.ZERO,
           intensity: float = 1.0, radius_px: float = 400.0,
           kind: String = "signal_light", at: float = 0.0,
           duration_sec: float = 0.0) -> void:
	self.source_id = source_id
	self.position = position
	self.intensity = intensity
	self.radius_px = radius_px
	self.kind = kind
	self.at = at
	if duration_sec > 0.0:
		expires_at = at + duration_sec
	else:
		expires_at = INF

## Has this signal stopped being active? True after expires_at passes.
func is_expired(now: float = -1.0) -> bool:
	if now < 0.0:
		now = ShipSystemEvent.now()
	return now >= expires_at

## Does this signal reach this world point? Distance from the source against
## radius. A listener in the middle of the disc hears it; one at the rim hears
## it weakly; outside it hears nothing.
func covers(point: Vector2) -> bool:
	if radius_px <= 0.0:
		return point.distance_squared_to(position) <= 0.0
	return position.distance_to(point) <= radius_px

## How strongly this signal reads at this point: 1.0 at the source, falling to
## 0.0 at the rim, and 0.0 beyond it. Listeners can weight their own reaction by
## this number - a distant signal is still a signal, just a quieter one.
func strength_at(point: Vector2) -> float:
	if not covers(point):
		return 0.0
	if radius_px <= 0.0:
		return intensity
	var reach := clampf(1.0 - position.distance_to(point) / radius_px, 0.0, 1.0)
	return clampf(intensity * pow(reach, 0.85), 0.0, 1.0)

## A shallow copy with the same fields - safe to hand out to listeners.
func duplicate() -> SignalMessage:
	var copy := new()
	copy.source_id = source_id
	copy.position = position
	copy.intensity = intensity
	copy.radius_px = radius_px
	copy.kind = kind
	copy.at = at
	copy.expires_at = expires_at
	return copy

## One dictionary, the same shape the ship's bus publishes. A panel or a test
## can read this without touching the message object itself.
func to_dict() -> Dictionary:
	return {
		"source_id": source_id,
		"kind": kind,
		"position": position,
		"radius_px": radius_px,
		"intensity": intensity,
		"at": at,
		"expires_at": expires_at,
	}
