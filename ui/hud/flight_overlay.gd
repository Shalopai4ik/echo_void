extends CanvasLayer
class_name FlightOverlay

## The live layer on top of the flight glass: waypoint, threat reading,
## system messages, the research line and the radio. Each piece is its own
## small control; this node only lays them out so they never cover the
## middle of the screen, where the ship flies.

var waypoint: WaypointMarker
var threat: ThreatMeter
var feed: NotificationFeed
var ticker: ResearchTicker
var comms: CommsPanel


func _ready() -> void:
	layer = 2
	var root := Control.new()
	root.name = "Root"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	waypoint = WaypointMarker.new()
	waypoint.name = "Waypoint"
	root.add_child(waypoint)
	waypoint.set_anchors_preset(Control.PRESET_FULL_RECT)

	threat = ThreatMeter.new()
	threat.name = "ThreatMeter"
	root.add_child(threat)
	_anchor_right(threat, 116.0, 196.0, 40.0)

	feed = NotificationFeed.new()
	feed.name = "Notifications"
	root.add_child(feed)
	_anchor_right(feed, 162.0, 236.0, 0.0)

	ticker = ResearchTicker.new()
	ticker.name = "ResearchTicker"
	root.add_child(ticker)
	ticker.anchor_left = 0.5
	ticker.anchor_right = 0.5
	ticker.offset_left = -170.0
	ticker.offset_right = 170.0
	ticker.offset_top = 10.0
	ticker.offset_bottom = 32.0

	comms = CommsPanel.new()
	comms.name = "Comms"
	root.add_child(comms)
	comms.anchor_left = 0.5
	comms.anchor_right = 0.5
	comms.anchor_top = 1.0
	comms.anchor_bottom = 1.0
	comms.offset_left = -255.0
	comms.offset_right = 205.0
	comms.offset_top = -150.0
	comms.offset_bottom = -88.0
	comms.grow_vertical = Control.GROW_DIRECTION_BEGIN


func _anchor_right(c: Control, top: float, width: float, height: float) -> void:
	c.anchor_left = 1.0
	c.anchor_right = 1.0
	c.offset_left = -18.0 - width
	c.offset_right = -18.0
	c.offset_top = top
	c.offset_bottom = top + height
	c.grow_horizontal = Control.GROW_DIRECTION_BEGIN


## Hide the whole layer (the end screen, a cutscene).
func set_shown(value: bool) -> void:
	visible = value
