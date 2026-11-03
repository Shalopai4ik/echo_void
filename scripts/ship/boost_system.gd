extends RefCounted
class_name BoostSystem

## Temporary authority over the main engine, paid for out of a charge.
##
## The rule this class exists to enforce: boost is a *multiplier on an existing
## engine*, never a second acceleration. It is asked one question - how much of
## `main_engine_max_power` may the plant reach this frame - and answers with a
## number around 1.0. The flight model multiplies its own `forward_acceleration` by
## the power that number produces, so there is still exactly one place where a
## newton enters the hull, and a test can still prove it.
##
## Nothing here knows about the hull's speed either. The ceiling the boost lifts
## (`max_forward_speed`) lives on the ship; this only reports the factor, and the
## ship decides what it means. That keeps 1.1's rule intact: a ceiling caps the
## thruster, never the world - a bounce that already threw the ship past the boosted
## ceiling keeps every px/s of it.
##
## Charge is deliberately a 0..1 ratio, not joules. The day a real energy system
## arrives, it replaces `boost_charge` through `set_charge()` and answers
## `take_charge()` instead of the internal tank; no number here is expressed in
## watts, no HUD is referenced, and the visual layer never sees the tank at all -
## it only ever reads the power the plant reached. So swapping the tank out touches
## this file and nothing else.

## The live tank, 0..1 of capacity. Named the same way the spec names it, because it
## is the same thing: the parameter seeds it, the runtime holds it.
var boost_charge := 1.0

## Whether the engine is being over-authorised this very frame - which needs the
## lever, the main engine, charge and no emergency brake, all at once.
var active := false

## The authority factor the plant is being asked for right now, 1.0 .. multiplier.
## Ramped, because an instant 1.8x on a hull already at cruise is a shove the pilot
## feels as a bug.
var factor := 1.0

## Ran the tank to empty and is waiting to be allowed to light again. This is the
## anti-pump lock: once the charge is gone, re-lighting needs the activation level,
## so tapping the lever cannot turn the last trickle of charge into bursts.
var cut_off := false

## Seconds since the boost last burned charge. Recovery waits this out.
var since_use := 0.0

## Which of the two locks stopped the boost from lighting last frame, for the panel:
## `ready` / `no-charge` / `empty` / `not-main` / `braking` / `off`.
var reason := "off"

## The numbers. Assigned by the ship from its own resource; a hand-built instance
## gets defaults so the system can never be null-dereferenced.
var parameters: ShipAssistParameters


func _init(params: ShipAssistParameters = null) -> void:
	parameters = params if params != null else ShipAssistParameters.new()
	boost_charge = parameters.boost_charge
	factor = 1.0


## The one entry point, called by the flight model once per physics frame before the
## main burn is applied.
##
## `lever` is the boost key held; `main_wanted` is W - the spec's condition that a
## boost nobody is driving with must not burn charge; `blocked` is the emergency
## brake, which outranks the engine entirely, so a ship being hauled to a stop does
## not simultaneously be thrown forward.
func step(lever: bool, main_wanted: bool, blocked: bool, delta: float) -> void:
	var p := settings()
	# One eligibility expression and one assignment. Writing this as a chain of "but
	# also" branches is how a boost that is supposed to stand down under an emergency
	# brake stays lit anyway: each branch remembers to record *why* and forgets to take
	# the request away. `reason` is now a report, never a gate.
	var eligible := p.boost_enabled and lever and main_wanted and not blocked \
		and boost_charge > 0.0
	# Lighting from dark needs the activation level; *staying* lit only needs charge.
	# Without that split a hull crossing 0.15 while burning would stutter, and the
	# tank would be unusable below the line even though it still holds charge.
	if not active:
		eligible = eligible and boost_charge >= p.boost_min_activation_charge
	active = eligible
	if active:
		reason = "lit"
	elif not p.boost_enabled:
		reason = "disabled"
	elif not lever:
		reason = "off"
	elif not main_wanted:
		reason = "not-main"
	elif blocked:
		reason = "braking"
	elif boost_charge <= 0.0:
		reason = "empty"
	else:
		reason = "low"

	if active:
		var before := boost_charge
		boost_charge = maxf(0.0, boost_charge - p.boost_drain_rate * delta)
		if before > 0.0 and boost_charge <= 0.0:
			# Spent to nothing: the lock goes on, and this frame is already the last
			# one the engine was over-authorised by it.
			cut_off = true
			active = false
			reason = "empty"
		since_use = 0.0
	else:
		# The lock is only released by charge, never by the lever: that is what makes
		# pumping Shift a dead end instead of a way to spend a trickle as a burst. A
		# held lever does get the boost back once the activation level is recovered,
		# which is what holding it means.
		if cut_off and boost_charge >= p.boost_min_activation_charge:
			cut_off = false
		since_use += delta
		if since_use >= p.boost_recharge_delay and boost_charge < 1.0:
			boost_charge = minf(1.0, boost_charge + p.boost_recharge_rate * delta)
	# Clamped on the way *up* as well as down: the ramp is symmetric, so a boost
	# released at full charge falls back to 1.0 over the same time it came in over.
	var target := p.boost_multiplier if active else 1.0
	factor = move_toward(factor, target, absf(p.boost_multiplier - 1.0)
		/ maxf(p.boost_ramp_time, 0.001) * delta)
	if factor <= 1.0001 and not active:
		factor = 1.0


## Multiply the plant's main authority by this. 1.0 when nothing is boosting, so a
## caller never has to know whether the system exists.
func power_multiplier() -> float:
	return factor


## The forward-speed ceiling factor, tracking the authority rather than leading it.
## The ceiling rises as the engine spools and falls as it bleeds off, so there is no
## frame in which the hull is suddenly below or above a limit it could not reach.
func speed_multiplier() -> float:
	var p := settings()
	var span := p.boost_multiplier - 1.0
	if span <= 0.0001:
		return p.boost_max_speed_multiplier
	var progress := clampf((factor - 1.0) / span, 0.0, 1.0)
	return 1.0 + (p.boost_max_speed_multiplier - 1.0) * progress


## Charge as a whole percent - the HUD's unit, not the model's.
func percent() -> int:
	return int(roundf(boost_charge * 100.0))


## How fast the tank is moving right now, in charge per second: negative while
## burning, positive while recovering, zero in the delay. A panel that prints the
## two rates separately is far easier to debug than one that prints the level alone.
func charge_rate() -> float:
	var p := settings()
	if active:
		return -p.boost_drain_rate
	if since_use >= p.boost_recharge_delay and boost_charge < 1.0:
		return p.boost_recharge_rate
	return 0.0


## The seam for a later energy system: whatever owns the tank in production writes
## the level here, and the clamp is the same one the internal recovery uses, so a
## replacement cannot smuggle a value outside 0..1.
func set_charge(value: float) -> void:
	boost_charge = clampf(value, 0.0, 1.0)


## Draw charge out (positive `amount`) or hand it back (negative). A future
## EnergySystem answers this instead of the internal tank doing its own arithmetic;
## nothing else in the ship knows the difference.
func take_charge(amount: float) -> void:
	set_charge(boost_charge - amount)


func settings() -> ShipAssistParameters:
	if parameters == null:
		parameters = ShipAssistParameters.new()
	return parameters


## The panel lines: state, charge, the two rates and the authority actually in
## force. Named exactly as the spec asks for them so a reader can tie a line to a
## parameter without hunting.
func report() -> Array[String]:
	var p := settings()
	# The state word is the reason, spelled for a panel: which of the gates is holding
	# the boost down is the first thing a reader wants to know when it is not lit.
	var state := "UNLIT"
	match reason:
		"lit":
			state = "ON"
		"off":
			state = "READY"
		"low":
			state = "LOW"
		"empty":
			state = "EMPTY"
		"not-main":
			state = "IDLE"
		"braking":
			state = "BLOCKED"
		"disabled":
			state = "DISABLED"
	return [
		"boost      %s (%s)" % [state, reason],
		"charge     %3d%%  %.2f/s" % [percent(), charge_rate()],
		"boost x    %.2f power  x%.2f max speed" % [factor, speed_multiplier()],
		"boost cfg  %.2f/%.2f  delay %.2fs  min %d%%  %s" % [
			p.boost_drain_rate, p.boost_recharge_rate, p.boost_recharge_delay,
			int(roundf(p.boost_min_activation_charge * 100.0)),
			"enabled" if p.boost_enabled else "disabled"],
	]
