extends Resource
class_name ShipWorldParameters

## The tuning surface of the hull's life outside the flight model (sub-stage 1.4).
##
## States, control availability, collision reporting and external influences. Like the
## two resources before it, this one owns numbers and nothing else: the flight model
## still integrates the hull, the plant still owns the powers, and the three assists
## still only borrow levers. What is added here is how the ship *describes itself* to
## the rest of the game, and how the rest of the game is allowed to touch it.
##
## The collision thresholds are in the one unit the hull actually speaks - px/s of
## closing speed - because Godot's 2D physics does not hand a `RigidBody2D` an
## impulse. `closing speed along the line between the two bodies` is what is genuinely
## available, so that is what is classified, and every report that comes out of the
## ship says so instead of pretending to a precision the server never gave it. The
## bands are set against the ship's own envelope: 780 px/s of cruise, 1053 at boost,
## so a head-on at full boost is HEAVY, a nudge while station-keeping is LIGHT.

@export_group("Collision reporting")
## Closing speed at or above which a contact becomes an event at all. Below it the
## hull is merely scraping along a rock - real, and not worth a signal.
@export_range(0.0, 2000.0, 5.0, "suffix:px/s") var light_collision_threshold: float = 45.0
## The next band up: a contact a pilot would call a hit.
@export_range(0.0, 2000.0, 5.0, "suffix:px/s") var medium_collision_threshold: float = 140.0
## The top band: a hit that a later damage stage will want to read seriously.
@export_range(0.0, 2000.0, 5.0, "suffix:px/s") var heavy_collision_threshold: float = 380.0
## Seconds during which the *same object* cannot raise another event, and the same
## floor for a second event of any kind. A hull grinding along a boulder touches three
## collision shapes in a frame; without a window that is three "collisions" per scrape,
## which is noise a listener cannot use.
@export_range(0.0, 5.0, 0.01) var collision_event_cooldown: float = 0.3
## How long a contact keeps the ship in the COLLISION state after it happened - the
## reaction window, not the event itself. Short, because a state that outlives the
## moment hides what the engines are doing.
@export_range(0.0, 3.0, 0.01) var collision_state_hold: float = 0.2

@export_group("External influences")
## The master switch for anything outside the ship pushing it. Off means
## `apply_external_*` is ignored and the panel says so - which is how a cutscene or a
## disabled anomaly can be tested without deleting the code that uses it.
@export var external_acceleration_enabled: bool = true
## Ceiling of the *sum* of every sustained external acceleration, px/s^2. A number a
## gravity well or a particle stream has to live inside, so that stacking five
## influences cannot out-push the main engine by accident.
@export_range(0.0, 4000.0, 10.0, "suffix:px/s^2") var max_external_acceleration: float = 420.0
## Ceiling of one instantaneous external change of velocity, px/s. The same argument as
## the engine ceilings: it limits what the world may hand the hull in one frame, not
## what the hull is allowed to keep.
@export_range(0.0, 4000.0, 10.0, "suffix:px/s") var max_external_impulse: float = 300.0

@export_group("Control and reporting")
## Whether a hull starts under control. The switch itself is the flight model's
## existing `movement_enabled` - this is only its initial value, so a scene that needs
## a ship that begins locked (a cargo bay, a wreck) can say so in the inspector.
@export var ship_control_enabled_by_default: bool = true
## How much the speed has to move before `ship_speed_changed` is emitted, px/s. The
## speed changes every physics frame; a listener should not have to filter a signal
## that fires sixty times a second for a drift of a hundredth.
@export_range(0.0, 500.0, 1.0, "suffix:px/s") var speed_report_threshold: float = 12.0
