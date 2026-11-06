extends Resource
class_name ScannerProfile

## Everything one survey sweep is allowed to do, as data.
##
## The numbers are the scanner's tuning surface and the `signatures` list is its
## whole vocabulary. A device carries a profile; a later upgrade system swaps the
## profile (or raises `ShipScanner.range_multiplier`) instead of editing the device,
## and a new kind of findable thing is a new signature here.
##
## One rule the defaults follow: a sweep is cheap because it asks the world for the
## objects inside a disc, not because it filters thousands of them. `candidate_factor`
## says how many candidates to ask for per reported contact, so a profile that only
## cares about three rare things can still fill its list without asking the world
## for everything it has.

@export_group("Sweep")
## Radius of the disc, from the hull, in world px. The world only answers for what
## it has streamed, so a range far past the screen finds less than the number says.
@export_range(64.0, 8000.0, 16.0, "suffix:px") var range_px := 1100.0
## How long a sweep takes. Contacts arrive one at a time across it, so a sweep is
## something the pilot waits on rather than a button that instantly answers.
@export_range(0.5, 30.0, 0.25, "suffix:s") var sweep_seconds := 3.5
## One-off energy cost of a sweep, paid atomically through the ship's reserve.
## Zero makes the sweep free, which is what a hull with no reserves layer does.
@export_range(0.0, 500.0, 1.0, "suffix:units") var sweep_energy_cost := 12.0
## Most contacts one sweep reports. A hard cap: a dense belt would otherwise put a
## hundred lines on a panel nobody can read.
@export_range(1, 256) var max_contacts := 48
## Candidates asked of the world per reported contact, before classification. Weak
## or unmatched objects are dropped after they arrive, and this is the allowance
## that keeps them from crowding the interesting ones out.
@export_range(1, 16) var candidate_factor := 8

@export_group("Returns")
## The vocabulary. Order matters: the first signature that matches a world object
## answers for it, so a specific population goes above a general group.
@export var signatures: Array[ScanSignature] = []

@export_group("Presentation")
## Art for a future scanner panel. Nothing reads it yet - the interface is its own
## sub-stage - but the profile is where a panel will look for it.
@export var icon: Texture2D
## Line a debug report prints above the signatures.
@export var title := "survey scanner"


## The signature that answers for this world object, or null when nothing does -
## and a null is the honest answer for background clutter nobody is meant to find.
func signature_for(population: String, group_names: Array, object_kind: String) -> ScanSignature:
	for signature in signatures:
		if signature != null and signature.matches(population, group_names, object_kind):
			return signature
	return null


## The signature with this id, or null. For a save file, a test or a panel.
func signature(id: String) -> ScanSignature:
	for signature in signatures:
		if signature != null and signature.id == id:
			return signature
	return null


## The signatures that have no object behind them. Separated because a sweep raises
## them from the world's hash rather than by asking the world for nodes.
func phantoms() -> Array[ScanSignature]:
	var out: Array[ScanSignature] = []
	for signature in signatures:
		if signature != null and signature.phantom and signature.phantom_chance > 0.0:
			out.append(signature)
	return out


## The lines the debug panel prints: the sweep's own numbers, then one line per
## signature. Built here rather than in the overlay so a headless run can read a
## profile without a renderer - the same rule every other `report()` follows.
func report() -> Array[String]:
	var lines: Array[String] = [
		"%s  range %.0f px  %.1f s  %.1f units  max %d" % [title, range_px,
			sweep_seconds, sweep_energy_cost, max_contacts],
	]
	for signature in signatures:
		if signature == null:
			continue
		if signature.phantom:
			lines.append("  %-14s phantom %.0f px  %.1f%%  detect %.2f  salt %d"
				% [signature.id, signature.phantom_cell,
					signature.phantom_chance * 100.0, signature.detect_at,
					signature.phantom_salt])
			continue
		lines.append("  %-14s %s  detect %.2f  identify %.2f  strength %.2f  %s"
			% [signature.id, signature.kind, signature.detect_at,
				signature.reveal_threshold(), signature.strength,
				"anomaly" if signature.uncertain_kind == "anomaly" else "signal"])
	return lines