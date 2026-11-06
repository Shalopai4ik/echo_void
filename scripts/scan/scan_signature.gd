extends Resource
class_name ScanSignature

## One kind of return a sweep can produce, and the whole vocabulary a scanner has.
##
## The scanner knows nothing about asteroids, wrecks or beacons. It knows that a
## world object answers a signature or it does not, and a signature is a resource:
## what it matches, how strong its return is, at what strength it is finally named,
## and which of the object's own numbers a pilot is allowed to read. Adding a new
## kind of findable thing is therefore a new entry in `ScannerProfile.signatures` -
## never an edit to `scanner_system.gd`.
##
## Three numbers decide what a pilot is told about one contact:
##
##     strength     how strong the return is at point-blank range, 0..1
##     detect_at    below this the object is not reported at all
##     identify_at  at or above this the contact is named; between the two it is a
##                  `uncertain_kind` - a signal with no name, which is the whole
##                  point of a survey game
##
## The measured return falls off with distance, so `identify_at` is also a range: a
## derelict reads as an anomaly from afar and as itself only when the hull is close.
## That is how "not everything is found on the first sweep" is expressed without a
## single line of scanner code.
##
## A signature may also have no object behind it at all (`phantom`). Then it does
## not match anything: it is rolled over a fixed lattice of world cells with the
## same hash the world generator uses, so the same anomaly is in the same place on
## every sweep and on every visit, and a later research stage can attach content to
## the cell it was raised from.

@export_group("Identity")
## Stable name in the profile, in logs and in `status()`.
@export var id := "signature"
## The reported kind once the contact is identified. Free text on purpose: the
## scanner only compares it with the kinds the world itself answers.
@export var kind := "unknown_object"
## What the panel calls it once identified. Empty means "ask the object", and an
## object that does not introduce itself falls back to this signature's id.
@export var title := ""
## What an unidentified return of this signature reads as. Two choices because the
## game tells two different stories: an `unknown_signal` is something out there, an
## `anomaly` is something out there that does not add up.
@export_enum("unknown_signal", "anomaly") var uncertain_kind := "unknown_signal"

@export_group("Matching")
## World populations (`SpaceObjectKind.label`) this signature answers for.
@export var populations := PackedStringArray()
## Node groups this signature answers for, e.g. `interactable`.
@export var groups := PackedStringArray()
## `WorldObjects.kind_of()` answers this signature answers for, e.g. `debris`.
@export var kinds := PackedStringArray()

@export_group("Return")
## Signal strength at zero distance. The measured strength is this, scaled by the
## falloff, the scanner's sensitivity and its condition.
@export_range(0.0, 1.0, 0.01) var strength := 0.5
## Weakest return that is reported at all.
@export_range(0.0, 1.0, 0.01) var detect_at := 0.05
## Return from which the contact is named. Clamped up to `detect_at` at read time,
## so a profile cannot ask to identify something it never reports.
@export_range(0.0, 1.0, 0.01) var identify_at := 0.4

@export_group("Reveal")
## Keys of the object's own `world_object_info()` a pilot may read once the contact
## is identified. Everything else the object knows stays inside the sweep - a
## survey ship does not learn what is in a wreck from a range finder.
@export var reveal_keys := PackedStringArray()

@export_group("Phantom")
## No object behind this signature: a signal source rolled over a lattice of cells.
## Never identified (`identify_at` above 1.0 keeps it an `uncertain_kind` until a
## research stage exists to make sense of it).
@export var phantom := false
## Side of the lattice cell, in world px. Raised to `range / 16` if it would make
## one sweep walk more than about a thousand cells.
@export_range(16.0, 8000.0, 16.0, "suffix:px") var phantom_cell := 1400.0
## Chance a cell holds a signal, decided by the cell's hash rather than by a roll.
@export_range(0.0, 1.0, 0.005) var phantom_chance := 0.05
## Salt of this signature's own lattice, so two phantom kinds never land together.
@export_range(0, 9999) var phantom_salt := 8111

## Used when the world cannot name its own seed. Only matters for phantoms.
@export var fallback_seed := 20261102


## Does this signature answer for the object with this population, these groups and
## this kind? An empty list is not a wildcard: a signature that matches nothing was
## never configured, and a catch-all would eat every contact behind its back.
func matches(population: String, group_names: Array, object_kind: String) -> bool:
	if phantom:
		return false
	if not populations.is_empty() and populations.has(population):
		return true
	if not kinds.is_empty() and kinds.has(object_kind):
		return true
	if not groups.is_empty():
		for name in group_names:
			if groups.has(String(name)):
				return true
	return false


## Is this return strong enough to be reported?
func detects(measured: float) -> bool:
	return measured > 0.0 and measured >= clampf(detect_at, 0.0, 1.0)


## Is this return strong enough to be named?
func identifies(measured: float) -> bool:
	return measured > 0.0 and measured >= maxf(identify_at, detect_at)


## The hidden threshold, for a test or a panel that wants to explain a sweep.
func reveal_threshold() -> float:
	return maxf(identify_at, detect_at)


## The name to show for a contact this signature did not title itself.
func fallback_title() -> String:
	return title if not title.is_empty() else id.replace("_", " ")