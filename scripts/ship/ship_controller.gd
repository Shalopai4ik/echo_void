extends RigidBody2D
class_name ShipController

## Sub-stage 1.1 - the flight model of the research ship.
##
## The ship is a `RigidBody2D` with no gravity and no hand-placed position: the
## physics server owns where it is, and every frame this controller only owns how
## fast it is going. That is what makes the hull feel like a machine with mass -
## W leans on it, letting go does not stop it, and a rock answers with a real
## impulse that the next frame reads back as the starting speed.
##
## The one rule the whole file is built around (spec 8): the velocity vector is
## never re-aimed at the nose. Turning the hull 180 degrees leaves the ship
## flying exactly where it was flying, and only thrust bends the path. The burns
## are computed in the hull's own axes - the main engine spends the speed under the
## nose and never touches the drift across it - so a hull can be pointed one way
## and thrown another for as long as the pilot lets it.
##
## The pipeline is one method per job, in this order: read the input, ask the three
## assists what they would like, resolve who owns which lever, ask the engine plant
## what that can deliver this frame, glide, retro burn (braking or astern, chosen
## from the real velocity), manoeuvring burn, main engine, rest threshold, integrate
## the yaw, hand over to the body. Keeping them apart is what makes S predictable:
## braking and reversing are two modes picked from the velocity, not one formula that
## flips sign under the pilot's hands.
##
## Since 1.2 the accelerations here are multiplied by the plant's power rather than
## applied whole: the engine system says how hard a group is working, this file says
## what that does to the hull. No force is computed twice, and `Ship.tscn`'s
## `Engines` node holds no `apply_*` call at all.
##
## Since 1.3 there are three more callers in front of those five levers - the pilot's
## keys, the stabilizer, the emergency brake and the boost - and the invariant above
## is the reason they could be added without touching the integration at all. They
## fill in a `FlightOrder`; `_resolve_order()` decides who won each axis; the plant
## turns that into powers; and the burn methods below are still the only four places
## a number is added to `linear_velocity` or `angular_velocity`. None of the three is
## a node, because a node would have its own `_physics_process`, and two of those
## against one hull is precisely the bug the spec warns about.
##
## The nose is +X, because that is how `assets/fighter.png` is drawn and how the
## hull slabs in `Ship.tscn` are measured: `tools/assemble_ship.py` prints those
## numbers, and staying in the art's own frame is what lets a redrawn hull drop in
## without touching a coordinate here.
##
## `Ship.tscn` pins the body's own damping to zero on purpose. Godot's project
## defaults (linear 0.1, angular 1.0) would stack an invisible second resistance
## on top of `linear_drag`, and then the exported number would stop being the
## whole of the ship's glide.
##
## Where the later stages plug in without touching this file:
## - damage and destruction: `obstacle_hit(obstacle, closing_speed)` already knows
##   what was hit and how hard; `body_shape_entered` adds a normal when needed.
## - fuel, upgrades, the reactor: re-scale or re-point the exported parameters. Boost
##   is already on that seam - `BoostSystem.take_charge()` and `set_charge()` are the
##   two calls a future `EnergySystem` answers instead of the internal 0..1 tank, and
##   nothing else in the ship knows which is providing the number.
## - flight controls cut away: `movement_enabled = false` stops the input *and* the
##   assists (every axis reads as pilot-held, so nothing is borrowed), the hull keeps
##   whatever momentum it already has.
## - the flight readout and the hull vectors: `scripts/ship/ship_debug.gd`, a child
##   node that switches itself on `show_debug` and never writes to the body.
## - scanner, modules, turret: children of this node, placed with `forward()` and
##   animated from `engines.main_power`.

## Which burn the retro lever is asking for right now, and the name the debug
## readout prints. Chosen from the real velocity every frame, never remembered
## from the last one.
enum Mode {
	## Nothing is burning: the hull is gliding, coasting or parked.
	IDLE,
	## W: the main engine, along the nose.
	FORWARD,
	## S with speed still on the ship: thrust pointed back along the velocity
	## vector, whatever way that happens to be.
	BRAKING,
	## S once the speed is gone: the astern thrusters, along the tail.
	REVERSING,
	## Space: the same retro plant as BRAKING, at the hardest deceleration it has
	## and on the shortest bite time. Its own name because the pilot needs to see
	## which hand is on the lever, and because an emergency burn that shares a label
	## with a controlled one cannot be told apart in a test either.
	EMERGENCY,
}

@export_group("Linear flight")
## Ceiling of the main engine along the nose. It caps the engine, not the world:
## a hard bounce still throws the ship faster and only `linear_drag` takes that
## back. The art is drawn at scale 2 and the camera sits at zoom 0.5, so this is
## about two and a half hull lengths a second and a screen crossing in 2.5 s.
@export_range(0.0, 4000.0, 1.0, "suffix:px/s") var max_forward_speed: float = 780.0
## Ceiling of the astern burn. Backing up is for station keeping, not running, so
## it sits at under a third of cruise on purpose.
@export_range(0.0, 4000.0, 1.0, "suffix:px/s") var max_reverse_speed: float = 240.0
## Main engine: how fast the nose-ward speed climbs toward `max_forward_speed`.
## Reached in about 1.7 s from a standstill, which is slow enough to read as mass.
@export_range(0.0, 4000.0, 1.0, "suffix:px/s^2") var forward_acceleration: float = 460.0
## Astern thrusters: deliberately weaker than the main engine, so holding S from
## a dead stop costs more time than holding W and the ship never backs away as
## sharply as it launches.
@export_range(0.0, 4000.0, 1.0, "suffix:px/s^2") var reverse_acceleration: float = 300.0
## Retro burn. The biggest number in the file: pulling 780 px/s down to nothing
## in about a second is what makes S feel like brakes instead of a second engine.
@export_range(0.0, 4000.0, 1.0, "suffix:px/s^2") var braking_acceleration: float = 760.0
## Fraction of the velocity the void takes per second while coasting: 0 is a
## perfect vacuum and the speed then falls as v0 * exp(-linear_drag * t). 0.18
## bleeds half of it off in under four seconds - long enough that a cut engine
## still carries the ship through a turn.
@export_range(0.0, 5.0, 0.01) var linear_drag: float = 0.18

@export_group("Angular flight")
## Steady yaw rate at full rudder. A 296 px hull swings slowly on purpose: this is
## a survey vessel, not an interceptor. Rotation is fully independent of linear
## speed, so the nose is still steerable parked in the void.
@export_range(0.0, 10.0, 0.01, "radians_as_degrees") var max_angular_speed: float = 1.7
## rad/s^2 on the rudder: 0.28 s from a tap to the full swing, which is the gap
## between "the nose follows the key" and "the nose is on a spring".
@export_range(0.0, 60.0, 0.05) var angular_acceleration: float = 6.0
## rad/s^2 once the rudder is let go, a little gentler than the ramp in so the
## ship keeps turning for a visible beat after the key.
@export_range(0.0, 60.0, 0.05) var angular_deceleration: float = 4.5

@export_group("Thresholds and switches")
## Below this the ship counts as stopped: braking hands over to reversing, and an
## idle hull with less speed left than this is parked for real instead of creeping
## on forever under the exponential glide.
@export_range(0.0, 200.0, 0.1, "suffix:px/s") var velocity_stop_threshold: float = 6.0
## Same idea for the yaw: under this the rotation is zeroed, which is what keeps a
## long flight from drifting a tenth of a degree a second with nothing pressed.
@export_range(0.0, 1.0, 0.001, "radians_as_degrees") var angular_stop_threshold: float = 0.02
## Cut the controls - a cutscene, a dead hull, a docking lock. Thrust and rudder
## stop, momentum and collisions keep working.
@export var movement_enabled: bool = true
## Flight diagnostics: hull vectors and a numeric readout. Off by default,
## because the void is the picture and this is a tool, not a HUD.
@export var show_debug: bool = false

## What the last frame's burn was doing, as `Mode`.
var movement_mode: Mode = Mode.IDLE
## The acceleration the engines commanded last frame, in world px/s^2. Glide and
## contact response are not inside it: this is what the pilot is asking for.
var commanded_acceleration := Vector2.ZERO

## The velocity the hull had at the beginning of this physics step. A contact signal is
## delivered after the server has already resolved the collision, so `linear_velocity` at
## the moment a handler runs is the speed the hull is leaving with - a head-on hit at
## cruise reads as zero or negative there. Everything that reports an impact reads this
## snapshot, which is the only honest "how fast did it arrive" a 2D body can give.
var velocity_before_step := Vector2.ZERO

## The world's own push, in world px/s^2: the clamped sum of every sustained external
## influence right now. Read by the state layer, the panel and anything that has to know
## whether the hull is being moved by something it did not choose.
var external_acceleration := Vector2.ZERO

## Fired the moment the hull touches something solid. The damage stage turns this
## into hurt: it already knows what was hit and how fast the gap was closing.
signal obstacle_hit(obstacle: Node, closing_speed: float)

## The richer contact report (sub-stage 1.4): what was hit, what kind of thing it is,
## how hard the two bodies came together and in which direction, all as one dictionary.
## Emitted at most once per `collision_event_cooldown` seconds, and never for a graze
## below `light_collision_threshold`, so a listener can react to it without filtering.
signal ship_collision_detected(info: Dictionary)

## The hull's own description changed (`ShipState.State`), and the control switch moved.
signal ship_state_changed(previous: int, current: int)
signal ship_control_enabled()
signal ship_control_disabled()

## Speed moved by more than `speed_report_threshold` px/s since the last time it fired.
## Deliberately throttled: the speed changes every physics frame, and a signal that
## fires sixty times a second for a hundredth of a px/s is a poll wearing a mask.
signal ship_speed_changed(speed: float)

## The state layer: primary state plus the flags of everything working at the same time.
var ship_state: ShipState

## The 1.4 tuning: collision bands, external-influence limits, the control default.
@export var world: ShipWorldParameters

# External influences, keyed by the id the caller gave them. A keyed set rather than one
# accumulated vector, because two anomalies that both push must be able to stop pushing
# independently - a sum with no source is how a hull ends up permanently drifting after
# the thing that was dragging it has gone.
var _external := {}
# An impulse waiting for the physics step. Queued, not applied where it was requested:
# a caller from a draw frame or a signal handler must not be able to move the body
# between two of the server's own steps.
var _pending_impulse := Vector2.ZERO
# The impulse this frame has taken responsibility for. Kept apart from the queue so a
# second request arriving mid-step cannot be applied twice.
var _external_kick := Vector2.ZERO

# Contact bookkeeping: the last event per object, the last event of any kind, and the
# report the panel prints. Keyed by instance id so a freed body leaves nothing behind.
var _contact_last := {}
var _contact_any := 0.0
var _last_collision := {}
var _speed_reported := 0.0

## The engine plant's tuning, with a default instance so a hull built in code
## without a resource still flies.
func settings() -> ShipEngineParameters:
	if parameters == null:
		parameters = ShipEngineParameters.new()
	return parameters


## The engine plant's tuning: response times, authority ceilings, the lateral
## group that has no flight-model counterpart, and how the jets look. The plant
## reads it; the flight model reads the plant.
@export var parameters: ShipEngineParameters

## The flight assists' tuning (sub-stage 1.3): what the stabilizer may borrow, how
## hard the emergency brake bites, what boost costs. A separate resource from the
## engine plant's on purpose - one file is "how the thrusters work", the other is
## "who is allowed to ask them for what" - and the same rule applies to both: no
## number here moves the hull by itself.
@export var assists: ShipAssistParameters

## The three assist systems. Plain objects, not nodes: they have no `_process` of
## their own and must not have one, because a second caller integrating the hull is
## precisely the failure this sub-stage is graded on. The flight model asks each one
## for a request, resolves who owns which lever, and applies one burn per axis.
var stabilization: StabilizationSystem
var emergency_brake: EmergencyBrakeSystem
var boost: BoostSystem

## The frame's resolved command: read by the plant and by every burn step below, and
## the only place the answer to "whose hand is on the retro lever" lives.
var _order := FlightOrder.new()

## The engine plant itself: who is burning, how hard, which way. Created in
## `Ship.tscn` as `Engines`; the fallback keeps a hand-built hull flying, and the
## plant's own `settings()` reaches back here for the parameters either way.
@onready var engines: EngineController = get_node_or_null("Engines")

# The four levers, sampled once per physics frame and read by every step below.
# Keeping them in fields rather than passing a struct around is what lets each
# step stay a one-line question about the flight.
var _thrust_input := false
var _retard_input := false
var _strafe_input := 0.0
var _rudder_input := 0.0
# The two 1.3 levers that are held rather than toggled: Space and Shift.
var _emergency_input := false
var _boost_input := false
# Last frame's state of the stabilization key. The toggle is edge-triggered - one
# press, one flip - but read by polling rather than from an input event, because a
# hull driven by `Input.action_press()` from a test, a gamepad or a script has no
# event to hand round either, and a latch does.
var _stabilization_latch := false


func _ready() -> void:
	add_to_group("ship")
	body_entered.connect(_on_body_entered)
	# The shape-level signal is the one that can say *which* of the hull's eleven slabs
	# touched, and it fires once per shape pair - which is also why the contact bookkeeping
	# below has a cooldown rather than trusting "one body, one event".
	body_shape_entered.connect(_on_body_shape_entered)
	if engines == null:
		engines = EngineController.new()
		engines.name = "Engines"
		add_child(engines)
	engines.parameters = parameters
	# The assists are created here rather than in the scene: they hold no node state,
	# and a hull built in code - or a legacy scene that never had them - still flies.
	if assists == null:
		assists = ShipAssistParameters.new()
	stabilization = StabilizationSystem.new(assists)
	stabilization.ship = self
	emergency_brake = EmergencyBrakeSystem.new(assists)
	boost = BoostSystem.new(assists)
	if world == null:
		world = ShipWorldParameters.new()
	ship_state = ShipState.new(self)
	# The control switch keeps one storage - `movement_enabled`, which the flight model
	# has honoured since 1.1 - and the resource only seeds it, in the one direction it
	# can do so without overwriting the scene: a hull that begins locked says so here, and
	# a hull that begins free simply keeps the export's own value.
	if not world.ship_control_enabled_by_default:
		set_control_enabled(false)
	_speed_reported = speed()


func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	# The arrival speed for any contact reported this frame has to be taken before the
	# burns, and before the server's own answer to last frame's overlap is overwritten.
	velocity_before_step = linear_velocity

	# 1. the levers, sampled once so every step below asks the same question.
	_read_input()

	# 2. what is left of the speed after the void has taken its share, in the
	# hull's own axes. The body's velocity is the only truth: whatever a bounce
	# earned is the speed the engines start from, and nothing below re-aims it at
	# the nose.
	var glide := _apply_glide(linear_velocity, delta)
	var ship_frame := _to_ship_frame(glide)

	# 3. the three assists look at the same frame the physics is about to be built
	# from, and each answers one question: what would you like the retro plant, the
	# manoeuvring pair and the verniers to do, and how hard. None of them is given
	# the hull, and none of them has a `_physics_process` to help it.
	var hands_on_hull := not movement_enabled
	emergency_brake.step(ship_frame, _emergency_input)
	stabilization.step(ship_frame, angular_velocity, _thrust_input or hands_on_hull,
		_retard_input or hands_on_hull, absf(_strafe_input) > 0.0 or hands_on_hull,
		absf(_rudder_input) > 0.0 or hands_on_hull, delta)
	# Boost is asked *after* the brake, because it needs to know the brake won: a
	# ship being hauled to a stop does not also get thrown forward, and its charge
	# is spent only while the main engine is genuinely driving.
	boost.step(_boost_input, _thrust_input and movement_enabled,
		emergency_brake.engaged, delta)

	# 4. one place where four hands become one command. The order is decided from
	# this frame's velocity, so the retro burn still aims at the speed the hull has,
	# whichever lever ends up holding it.
	#
	# The world's own push is summed first, for one reason: `_enforce_rest` below has to
	# know whether anything outside the ship is moving it. A hull being towed at a gentle
	# 60 px/s^2 would otherwise be parked by the rest threshold every frame and never
	# gather the speed the tow is asking for.
	_collect_external()
	_resolve_order(ship_frame)
	engines.step(_order, delta)

	# 5. the burns, each multiplied by the power its group reached, and never
	# applied twice: this is the only place a force enters the hull.
	var burned := _apply_retro(ship_frame, delta)
	var sideways := _apply_strafe(burned, delta)
	var driven := _apply_main_engine(sideways, delta)
	var commanded := _to_world(driven)
	commanded_acceleration = (commanded - glide) / delta

	# 6. angular motion, then the rest threshold, then the hand-over to the body.
	_step_yaw(delta)
	linear_velocity = _enforce_rest(commanded)

	# 7. last, and outside the engine arithmetic: what the world is doing to the hull.
	# Sustained pushes and queued impulses both land here, after the burns, so an
	# influence never gets multiplied by an engine's authority or capped by a thruster's
	# ceiling - the ceilings belong to the engines, and 1.1's rule is that they cap the
	# thrusters and not the world.
	_apply_external(delta)

	# 8. the state layer reads the finished frame and says out loud what it was.
	_report_state(delta)



# ---------------------------------------------------------------- 1. the input --

## Sample the InputMap once per frame. Nothing below this line looks at keys:
## every lever arrives as an action, so a rebinding or a gamepad is a project
## setting and not a code change. Pressing several actions at once is normal
## here, including W and S together - the engines answer each on its own terms.
func _read_input() -> void:
	# The stabilization key is a switch, so its edge is latched even while the hull
	# is not under control: the key goes down, the state flips once, and a ship with
	# the controls cut cannot be flipped a second time by the same press.
	var stabilization_key := Input.is_action_pressed("toggle_stabilization")
	if stabilization_key and not _stabilization_latch and movement_enabled:
		stabilization.toggle()
	_stabilization_latch = stabilization_key
	if not movement_enabled:
		_thrust_input = false
		_retard_input = false
		_strafe_input = 0.0
		_rudder_input = 0.0
		_emergency_input = false
		_boost_input = false
		return
	_thrust_input = Input.is_action_pressed("thrust_forward")
	_retard_input = Input.is_action_pressed("thrust_backward")
	# get_axis, not booleans: opposite levers cancel instead of fighting, and an
	# analog stick arrives already scaled between -1 and 1. Q and E are the
	# manoeuvring pair, -1 port and +1 starboard of the hull.
	_strafe_input = Input.get_axis("strafe_left", "strafe_right")
	_rudder_input = Input.get_axis("turn_left", "turn_right")
	_emergency_input = Input.is_action_pressed("emergency_brake")
	_boost_input = Input.is_action_pressed("boost")


# ------------------------------------------- 1b. whose lever is whose -------

## Four hands, five levers, one frame - and this is the only place that decides
## which hand wins. The rules, in the order they are applied:
##
## 1. `emergency_brake` owns the hull's linear retard, entirely, and takes W away
##    while it does. It is the one assist allowed to outrank a pilot's throttle:
##    a ship being thrown forward and hauled back at the same time reaches neither
##    answer, and the panel would have to print two truths about one vector.
## 2. `thrust_backward` owns the retro lever ahead of the stabilizer, exactly as 1.1
##    made it: the pilot's S decides braking-versus-reversing from the real velocity,
##    and the assist never asks for astern, because astern *makes* speed.
## 3. Q/E and A/D stay the pilot's while they are held, per lever - not per system -
##    so dodging sideways or pointing the nose while a stabilizer works costs nothing
##    to the pilot and takes the axis off the assist's hands.
## 4. The stabilizer fills the levers nobody is holding, and only with the authority
##    its own caps allow, which is always less than the pilot's number for that
##    group. It is the weakest hand on every axis, and that is the whole of its
##    safety argument: nothing it does is irreversible, because pressing the lever
##    takes the axis back on the frame it is pressed.
## 5. Boost multiplies the main engine's authority and nothing else. It is not a
##    lever owner - it is a ceiling on one, which is why brake, strafe and rotation
##    never see it, and why the plant's own ramp is still what shapes the burn.
##
## Each `owner_*` string says who got the lever, so a frame can be argued about from
## the panel alone instead of from a guess about which system was thinking at the
## time.
func _resolve_order(ship_frame: Vector2) -> void:
	_order.reset()
	_order.retro_deceleration = braking_acceleration
	_order.forward_ceiling = max_forward_speed * boost.speed_multiplier()

	# The main engine: W, unless the emergency brake has the hull's linear job.
	_order.main_thrust = _thrust_input and not emergency_brake.engaged
	if _order.main_thrust:
		_order.main_scale = boost.power_multiplier()
		_order.owner_main = "boost" if boost.active else "pilot"

	# The sideways and yaw axes: the pilot's keys first, the assist's correction for
	# whatever is not being pressed.
	_order.strafe_axis = _strafe_input
	_order.rudder_axis = _rudder_input
	if absf(_order.strafe_axis) < 0.001:
		_order.strafe_axis = stabilization.lateral
		_order.strafe_scale = stabilization.strafe_authority()
		_order.owner_strafe = "stabilizer" if absf(stabilization.lateral) > 0.0 else "-"
	else:
		_order.owner_strafe = "pilot"
	if absf(_order.rudder_axis) < 0.001:
		_order.rudder_axis = stabilization.spin
		_order.rotation_scale = stabilization.rotation_authority()
		_order.owner_rudder = "stabilizer" if absf(stabilization.spin) > 0.0 else "-"
	else:
		_order.owner_rudder = "pilot"

	# The retro lever, three hands in strict order.
	if emergency_brake.engaged:
		_order.retard = EngineController.Retard.BRAKING
		_order.brake_direction = -ship_frame.normalized()
		_order.retro_deceleration = emergency_brake.deceleration
		_order.brake_rise = assists.emergency_brake_response_time
		_order.owner_retro = "emergency"
	elif _retard_input:
		_order.retard = _retard_mode(ship_frame)
		_order.brake_direction = -ship_frame.normalized()
		_order.owner_retro = "pilot"
	elif stabilization.along != 0.0:
		# The assist's along-axis only. `stabilization.along` is already the direction
		# the push has to be in to take that component away, and the burn below spends
		# it on the nose axis alone - the sideways half belongs to the manoeuvring
		# pair, and letting both spend the same px/s is how a stabilizer becomes a
		# hover-thruster.
		_order.retard = EngineController.Retard.BRAKING
		_order.brake_direction = Vector2.RIGHT * stabilization.along
		_order.brake_scale = stabilization.retro_authority()
		_order.owner_retro = "stabilizer"


# ------------------------------------------------------- 2. angular momentum --

## Yaw with inertia. The rate is integrated, never assigned: a tap buys a small
## turn, holding it walks the rate up to `max_angular_speed`, letting go coasts the
## rate back down over `angular_deceleration`. Against the opposite rudder the
## ship first loses the rotation it had and only then picks up the new one, which
## is exactly what a hull with mass does.
##
## The stabilizer's turn is a different shape of command, and it has to be. A pilot
## aims at a *rate*; an assist aims at *zero rate*. Give the assist the pilot's form
## and it asks for full rudder against the spin, the rate crosses zero, the sign it
## was derived from flips, and the hull buzzes on its own axis at twice the dead
## zone - so the borrowed verniers add to the passive damping against a target of
## still, capped by the assist's own ceiling, and the rate is never carried past it.
func _step_yaw(delta: float) -> void:
	var rate := angular_velocity
	if _order.owner_rudder == "stabilizer":
		var bite := minf(angular_deceleration
			+ angular_acceleration * absf(engines.rotation_demand()),
			assists.stabilization_max_angular_correction)
		rate = move_toward(rate, 0.0, bite * delta)
		if absf(rate) < angular_stop_threshold:
			rate = 0.0
		angular_velocity = rate
		return
	var wanted := _order.rudder_axis * max_angular_speed
	if wanted != 0.0:
		# move_toward handles the reversal by itself: the distance to the wanted
		# rate is crossed at the verniers' authority, through zero and out the other
		# side, so no branch has to name the two cases. The authority is the engine
		# plant's ramped power, so a cold start turns the nose gently and a stuck
		# held for a second gets the whole of `angular_acceleration` behind it.
		var ramp := angular_acceleration * absf(engines.rotation_demand())
		if signf(wanted) != signf(rate) and rate != 0.0:
			# Already spinning the other way, the rudder is a brake first, and
			# braking is a firmer job than picking the rate up.
			ramp = maxf(ramp, angular_deceleration)
		rate = move_toward(rate, wanted, ramp * delta)
	else:
		rate = move_toward(rate, 0.0, angular_deceleration * delta)
		if absf(rate) < angular_stop_threshold:
			rate = 0.0
	angular_velocity = rate


# ------------------------------------------------------- 3. linear momentum --

## The hull's own axes: x under the engine, y across it. Working in this frame is
## what keeps "forward" a property of the ship and "drift" a property of the
## moment - and the basis is orthonormal, so lengths and the exponential glide
## mean the same thing here as they do in world space.
func _to_ship_frame(velocity: Vector2) -> Vector2:
	var nose := forward()
	return Vector2(velocity.dot(nose), velocity.dot(starboard()))


func _to_world(ship_frame: Vector2) -> Vector2:
	var nose := forward()
	return nose * ship_frame.x + starboard() * ship_frame.y


## Space resistance. Weak, exponential and frame-rate independent, and the only
## thing that ever takes speed back when the engines are off - which is why the
## ship carries on flying after W is released instead of stopping on the spot.
func _apply_glide(velocity: Vector2, delta: float) -> Vector2:
	if linear_drag <= 0.0:
		return velocity
	return velocity * exp(-linear_drag * delta)


## S, and the decision the whole lever rests on: the same key is a brake while the
## ship has speed and an astern engine once it does not. Braking aims at nothing
## but the current velocity vector, so a broadside drift gets burned off even
## though there is no engine pointing at it, and a stop is a stop - the direction
## cannot flip, because the burn is capped at the speed that is left.
func _retard_mode(ship_frame: Vector2) -> int:
	if not _retard_input:
		return EngineController.Retard.NONE
	var speed := ship_frame.length()
	if speed <= velocity_stop_threshold:
		return EngineController.Retard.ASTERN
	# Two tests, not one: the ship has to be moving, and its motion has to be
	# mostly *backwards along the nose* before the astern thrusters take over. The
	# second half is what keeps spec 6's example working - a hull flown broadside
	# has a small negative nose-ward projection simply because the rudder overshoots
	# ninety degrees by a frame, and reading that as "already going backwards" would
	# hand a lateral speed of seven hundred to the astern engine instead of the
	# brakes. It is also what stops the two modes from arguing: as the retro burn
	# eats a sideways flight the ratio stays put until the speed is gone, and as the
	# astern engine walks the ship tail-first the ratio only grows.
	if absf(ship_frame.x) < speed * 0.5 or ship_frame.x > -velocity_stop_threshold:
		return EngineController.Retard.BRAKING
	return EngineController.Retard.ASTERN


## The retro burn, whichever hand is on the lever, and the one place its force is
## applied. Written as a projection - `brake_direction` is the push, its opposite is
## the axis of speed being taken away, and the burn is capped at how much of *that
## axis* is left - which keeps both of the rules this has to hold:
##
## - The pilot's S, whose direction came from the whole velocity vector, spends the
##   whole of `speed` and so behaves exactly as it did in 1.1: a broadside drift is
##   burned off even though no engine points at it, and the direction cannot flip
##   because the burn stops at zero along that axis.
## - The stabilizer's along-axis request, whose direction is the nose axis, spends
##   only `|x|` and never reaches across into the sideways component the manoeuvring
##   pair is already paying for. That is what stops the two groups from killing the
##   same px/s twice, and it is why a borrowed retro burn cannot slow a drift.
func _apply_retro(ship_frame: Vector2, delta: float) -> Vector2:
	movement_mode = Mode.IDLE
	if _order.retard == EngineController.Retard.ASTERN:
		movement_mode = Mode.REVERSING
		# Astern: only ever pushes the nose-ward speed further back, and never past
		# the astern ceiling. A bounce that already threw the ship tail-first faster
		# than that keeps its speed - the ceiling caps the thrusters, not the world.
		if ship_frame.x > -max_reverse_speed:
			ship_frame.x = maxf(ship_frame.x
				- reverse_acceleration * engines.astern_power * delta, -max_reverse_speed)
		return ship_frame
	if _order.retard != EngineController.Retard.BRAKING:
		return ship_frame
	movement_mode = Mode.EMERGENCY if _order.owner_retro == "emergency" else Mode.BRAKING
	# The axis the speed is being removed along: the opposite of the push. Unit by
	# construction, so the projection below is a signed speed and nothing else.
	var axis := -_order.brake_direction
	var along := ship_frame.dot(axis)
	if along <= 0.0:
		# Already no speed left along this axis: the burn would add one instead of
		# taking it away, which is the overshoot the spec calls a bug.
		return ship_frame
	var burn := minf(_order.retro_deceleration * engines.brake_power * delta, along)
	return ship_frame - axis * burn


## Q and E: thrust across the hull, perpendicular to the nose and through the
## centre of mass. Three things this has to get right, and they are all in the
## spec: it never turns the ship (nothing here touches `angular_velocity`, so a
## pilot can hold an object dead-centre while sliding past it), the sideways speed
## is capped the same way the forward one is - the thrusters stop adding at
## `max_lateral_speed` rather than shaving a faster drift down to it - and when the
## key comes off, whatever lateral speed was earned stays earned.
##
## Since 1.3 the same line serves the stabilizer as well: `engines.strafe_demand()`
## is the ramped, authority-scaled power of whoever holds the lever, and the assist's
## ceiling arrived through `strafe_scale` on the order. A borrowed slide and a keyed
## one are the same four statements about the hull, which is the reason there is only
## one of each.
func _apply_strafe(ship_frame: Vector2, delta: float) -> Vector2:
	var demand := engines.strafe_demand()
	if absf(demand) < 0.001:
		return ship_frame
	var push := demand * settings().maneuvering_engine_power * delta
	if signf(push) == signf(ship_frame.y) and absf(ship_frame.y) >= settings().max_lateral_speed:
		return ship_frame
	if absf(ship_frame.y) > 0.001 and signf(push) != signf(ship_frame.y) \
			and absf(push) > absf(ship_frame.y):
		# An opposing sideways burn stops at the slide that is actually there. Without
		# this the stabilizer cancelling a 3 px/s drift would land the hull at 3 px/s
		# the *other* way, find the drift had flipped, and chase it back - a limit
		# cycle that reads as a ship that never quite parks. The same cap the retro
		# burn has carried since 1.1, applied to the axis this group owns.
		#
		# The 0.001 floor is not decoration. A hull flying along its own nose has a
		# sideways component of a few ten-thousandths, which is a rounding residue and
		# not a slide - and clamping against it pins `y` at zero and swallows the
		# pilot's E entirely. That was caught by a probe, not by a reader: at a parked
		# start the residue is exactly 0.0 and the same code looked right.
		push = -ship_frame.y
	ship_frame.y += push
	return ship_frame


## W along the nose. `if along < ceiling` is the load-bearing part: the engine adds
## up to the ceiling and stops there, so it can never carve a fast forward glide down
## to cruise, and the sideways component is left completely alone - turning while
## flying still lets the hull point somewhere the ship does not go.
##
## Under boost the ceiling is `max_forward_speed * boost.speed_multiplier()` and
## `engines.main_power` has been allowed past 1.0, which is the whole of how 1.3
## differs from a second engine: the same `forward_acceleration`, the same cap shape,
## the same single addition - the ceiling just tracks the authority instead of
## jumping ahead of it, so there is no frame in which the hull is suddenly allowed a
## speed it could not have reached.
func _apply_main_engine(ship_frame: Vector2, delta: float) -> Vector2:
	if not _order.main_thrust:
		return ship_frame
	var ceiling := _order.forward_ceiling
	if ship_frame.x >= ceiling:
		return ship_frame
	# With both levers on, the retro burn keeps the name: what the pilot is
	# fighting for is the slowdown, and the engine is just paying part of it.
	if movement_mode == Mode.IDLE:
		movement_mode = Mode.FORWARD
	ship_frame.x = minf(ship_frame.x
		+ forward_acceleration * engines.main_power * delta, ceiling)
	return ship_frame


## Everything under `velocity_stop_threshold` with no lever on it becomes a dead
## stop. The glide is asymptotic, so without this the hull creeps for a minute
## more at speeds the eye cannot see, and a parked ship is supposed to sit still.
## Only when nothing is burning, or the release of W would kill the very inertia
## this stage is about.
##
## Read off the resolved order rather than the keys since 1.3: an assist holding a
## lever counts as a lever being held, and the stabilizer's own dead zone is what
## releases it. That ordering - assist stops at `stabilization_dead_zone`, the hull's
## rest snap finishes below `velocity_stop_threshold` - is why a stabilized stop ends
## in a park instead of a tremble.
func _enforce_rest(velocity: Vector2) -> Vector2:
	if _order.main_thrust or _order.retard != EngineController.Retard.NONE \
			or absf(_order.strafe_axis) > 0.0:
		return velocity
	# Something outside the ship is moving it, so "no levers held" is no longer the whole
	# question. Without this a slow tow, a drift current or a gravity well would be
	# cancelled sixty times a second by a threshold that was written for a parked hull.
	if external_acceleration.length_squared() > 0.0 or _external_kick.length_squared() > 0.0:
		return velocity
	if velocity.length() < velocity_stop_threshold:
		return Vector2.ZERO
	return velocity


# ----------------------------------------------------------- 7. the world ------

## The sum of every sustained external influence, clamped once for the whole set rather
## than per source: five anomalies at 100 px/s^2 must not out-push the main engine just
## because none of them individually asked to. Disabled by the switch, and the panel
## prints the difference between "nothing is pushing" and "pushing is turned off".
func _collect_external() -> void:
	_external_kick = _pending_impulse
	_pending_impulse = Vector2.ZERO
	external_acceleration = Vector2.ZERO
	if not world.external_acceleration_enabled or _external.is_empty():
		return
	var sum := Vector2.ZERO
	for id in _external:
		sum += _external[id]
	if sum.length() > world.max_external_acceleration:
		sum = sum.normalized() * world.max_external_acceleration
	external_acceleration = sum


## Hand the hull over to the body. Both terms are accelerations in world space, so
## nothing here knows or cares which way the nose points - an external push is never
## re-aimed at the hull, exactly like a bounce.
func _apply_external(delta: float) -> void:
	var pushed := linear_velocity
	if external_acceleration.length_squared() > 0.0:
		pushed += external_acceleration * delta
	if _external_kick.length_squared() > 0.0:
		var kick := _external_kick
		if kick.length() > world.max_external_impulse:
			kick = kick.normalized() * world.max_external_impulse
		pushed += kick
	_external_kick = Vector2.ZERO
	linear_velocity = pushed


## Ask for a sustained external acceleration, in world px/s^2, under an id the caller
## owns. It lasts until the same id is removed or cleared, which is what a gravity well
## or a particle stream needs - and the id is what lets five different influences stop
## independently instead of leaving a residue of the one that went away first.
func add_external_acceleration(id: String, acceleration: Vector2) -> void:
	if not world.external_acceleration_enabled:
		return
	_external[id] = acceleration


## A one-frame change of velocity from outside: a shove, an explosion's edge, a docking
## clamp letting go. Queued for the next physics step, so no caller from a draw frame or
## a signal handler can move the body between two of the server's own steps, and capped
## by `max_external_impulse` before it is ever applied.
func apply_external_impulse(impulse: Vector2) -> void:
	if not world.external_acceleration_enabled:
		return
	_pending_impulse += impulse


func remove_external_acceleration(id: String) -> void:
	_external.erase(id)


func clear_external_accelerations() -> void:
	_external.clear()
	_external_kick = Vector2.ZERO


## How many influences are pushing right now - the panel's count, and the number a
## future anomaly manager needs to know whether it has finished cleaning up.
func external_influence_count() -> int:
	return _external.size()


## The control switch, spelled the way the rest of the game will call it. One storage
## (`movement_enabled`), three names for it, and two signals so anything that cares -
## a HUD, an animation, a scanner - can listen instead of poll.
func enable_control() -> void:
	set_control_enabled(true)


func disable_control() -> void:
	set_control_enabled(false)


## Cutting the controls takes the *input* away and nothing else. The hull keeps every
## px/s it had, the engines finish the ramps they were on, the assists stop borrowing
## (every axis reads as pilot-held, so no lever is left half-asked-for), and the state
## layer says DISABLED. There is no hidden brake in here, on purpose: a cutscene that
## stops the ship has to say so by moving it, not by switching the pilot off.
func set_control_enabled(value: bool) -> void:
	if movement_enabled == value:
		return
	movement_enabled = value
	if value:
		ship_control_enabled.emit()
	else:
		# The levers are dropped the same frame the switch goes: a key that was down when
		# control was taken away must not still be commanding a burn while the pilot is
		# supposedly not flying.
		_thrust_input = false
		_retard_input = false
		_strafe_input = 0.0
		_rudder_input = 0.0
		_emergency_input = false
		_boost_input = false
		ship_control_disabled.emit()


# ------------------------------------------------------------- 4. readout ------

## The hull touched something solid. `closing_speed` is the component of the ship's own
## velocity along the line to that body - the number the damage stage wants, unchanged
## from 1.1 so the world tests that count contacts keep meaning the same thing.
func _on_body_entered(body: Node) -> void:
	var toward := global_position.direction_to(body.global_position)
	obstacle_hit.emit(body, maxf(0.0, velocity_before_step.dot(toward)))


## The classified contact report. Built from the shape signal rather than from
## `body_entered` because a hull of eleven slabs can meet one rock through three of them
## in the same frame, and a listener that is told "a collision happened" three times for
## one scrape learns to ignore the signal.
##
## What is exact and what is estimated is stated in the dictionary itself, because Godot's
## 2D bodies do not hand out a contact point or an impulse: `RigidBody2D` has
## `get_contact_count()` and nothing else that names the collider, so the point below is
## the nearest surface along the centre-to-centre line and the intensity is a closing
## speed, not a newton-second. A future damage stage that wants the real impulse has to
## ask the server for it through a query, not read these fields and believe them.
func _on_body_shape_entered(_body_rid: RID, body: Node, body_shape_index: int,
		local_shape_index: int) -> void:
	if body == null or not is_instance_valid(body):
		return
	var other_position := (body as Node2D).global_position if body is Node2D \
		else global_position
	var distance := global_position.distance_to(other_position)
	var direction := global_position.direction_to(other_position)
	var other_velocity := Vector2.ZERO
	var as_body := body as RigidBody2D
	if as_body != null and not as_body.freeze:
		other_velocity = as_body.linear_velocity
	var relative := velocity_before_step - other_velocity
	var closing := maxf(0.0, relative.dot(direction))
	if closing < world.light_collision_threshold:
		# A graze. Real contact, and not an event: this is the floor under which the
		# hull is sliding along something rather than hitting it, and it is also what
		# keeps a parked ship resting on a rock from reporting forever.
		return
	var id := body.get_instance_id()
	var now := _now_seconds()
	var last_here: float = _contact_last.get(id, -1000.0)
	if now - last_here < world.collision_event_cooldown:
		return
	var extent := 0.0
	var declared = body.get("extent")
	if declared is float or declared is int:
		extent = float(declared)
	var info := {
		"object": body,
		"description": WorldObjects.describe(body),
		"kind": WorldObjects.kind_of(body),
		"category": _category_for(closing),
		"closing_speed": closing,
		"relative_velocity": relative,
		"direction": direction,
		"contact_point": global_position + direction * maxf(0.0, distance - extent),
		"point_is_estimate": true,
		"intensity_is_estimate": true,
		"distance": distance,
		"body_shape_index": body_shape_index,
		"local_shape_index": local_shape_index,
		"at": now,
	}
	_contact_last[id] = now
	_prune_contacts(now)
	_last_collision = info
	ship_state.note_collision()
	ship_collision_detected.emit(info)


## Which band a closing speed falls in. The thresholds are the ship's own, in px/s, and
## the bands are deliberately coarse: this is a classification of an estimate, and a
## fourth decimal place on a number derived from centre-to-centre geometry would be a
## precision the physics server never supplied.
func _category_for(closing: float) -> String:
	if closing >= world.heavy_collision_threshold:
		return "HEAVY"
	if closing >= world.medium_collision_threshold:
		return "MEDIUM"
	return "LIGHT"


## Physics time, not wall time: a test that steps the tree at its own pace has to see the
## same cooldowns the game does.
func _now_seconds() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


## Bodies that have left the tree would otherwise keep their cooldown entry forever.
func _prune_contacts(now: float) -> void:
	if _contact_last.size() < 32:
		return
	for id in _contact_last.keys():
		if not is_instance_id_valid(id) or now - float(_contact_last[id]) > 10.0:
			_contact_last.erase(id)


## The last contact the ship reported, or an empty dictionary. The `object` entry may
## point at a freed body - the world streams rocks out of a pool - so readers check
## `object_valid` rather than assuming the node is still there.
func last_collision() -> Dictionary:
	if _last_collision.is_empty():
		return {}
	var out := _last_collision.duplicate(true)
	var touched = out.get("object")
	# The body may have been freed since - the world field streams rocks out of a pool -
	# so the description, which is a plain dictionary taken at the moment of contact, is
	# what survives, and `object_valid` says whether the node still does.
	out["object_valid"] = touched != null and is_instance_valid(touched)
	out["age"] = _now_seconds() - float(out.get("at", 0.0))
	return out


## The state layer's turn: read the finished frame, and say what changed. Signals only go
## out on a real transition or a real move in speed, so a listener is never woken by the
## sixty-times-a-second nothing that a physics step would otherwise report.
func _report_state(delta: float) -> void:
	var previous := ship_state.primary
	if ship_state.step(_order, delta):
		ship_state_changed.emit(previous, ship_state.primary)
	var now := speed()
	if absf(now - _speed_reported) >= world.speed_report_threshold:
		_speed_reported = now
		ship_speed_changed.emit(now)


# ------------------------------------------------------------- 5. accessors ----

## Where the nose points, in world space.
func forward() -> Vector2:
	return Vector2.RIGHT.rotated(rotation)


## Signed speed along the nose: negative while the retro burn is backing up.
func forward_speed() -> float:
	return linear_velocity.dot(forward())


## Speed across the nose - the drift a pilot has to burn off before docking.
## Positive is drift to the ship's right, which is why the axis is spelled out
## rather than taken from `Vector2.orthogonal()`: that one rotates the other way,
## and a readout that prints a rightward drift as a negative number is a lie in
## the one place the stage is meant to be read.
func drift_speed() -> float:
	return linear_velocity.dot(starboard())


## The hull's right-hand side in world space: +90 deg, which on a y-down screen is
## the ship's starboard.
func starboard() -> Vector2:
	return forward().rotated(PI * 0.5)


## How fast the hull is actually moving, whichever way that is.
func speed() -> float:
	return linear_velocity.length()


## Which way the burning engines are pushing, world space. The brake nozzles read
## this, the diagnostics print it, and a later targeting stage will find it more
## useful than the nose: it is the direction the ship is being *forced*, which on a
## hull coasting broadside has nothing to do with where it is pointing.
func thrust_direction() -> Vector2:
	return engines.thrust_direction()


## The mode name the diagnostics print.
func mode_name() -> String:
	return Mode.keys()[movement_mode]


## Who has each lever this frame, exactly as the resolver decided it. Printed by the
## panel because every argument about an assist - "the stabilizer is fighting my E",
## "boost is burning charge while I coast" - is an argument about ownership, and a
## frame that names its own owners settles it without a debugger.
func owners() -> String:
	return "%s|%s|%s|%s" % [_order.owner_main, _order.owner_retro,
		_order.owner_strafe, _order.owner_rudder]


## The hull's own word for what it is doing, and the list of everything working at the
## same time. `ship_state` is the object; these two are the convenience the rest of the
## game will call, so nobody has to know that the state lives in a separate file.
func state_name() -> String:
	return ship_state.name_of() if ship_state != null else "NORMAL"


func active_systems() -> String:
	return ship_state.flags_text() if ship_state != null else "none"


## The primary state as the enum, for a listener that would rather compare than match
## text: `if ship.ship_state_value() == ShipState.State.BOOSTING`.
func ship_state_value() -> int:
	return ship_state.primary if ship_state != null else ShipState.State.NORMAL
