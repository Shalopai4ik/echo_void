extends Resource
class_name ResearchType

## One kind of thing the research system can analyse, as data.
##
## A research type describes how long a subject of this kind takes to analyse,
## how much research XP it awards, how complex it is, and which scanner
## signatures it matches. Adding a new kind of researchable object is a new
## entry here - never an edit to research_system.gd.
##
## Matching: a scanner contact answers for this type when its `signature`
## field is in `signature_ids`, or its `kind` field is in `kinds`. The first
## type in the profile's list that matches answers for the contact.

@export_group("Identity")
## Stable name used in save data, signals and `status()`. Changing this
## invalidates old save entries for this type.
@export var type_id: String = "research_type"
## What a panel or log calls this kind of subject.
@export var display_name: String = "Unknown subject"

@export_group("Matching")
## Scanner signature ids this type applies to, e.g. ["asteroid", "resonance"].
## A contact whose `signature` field matches one of these is researchable as
## this type. An empty list means "match by kind only".
@export var signature_ids: PackedStringArray = []
## Object kinds this type applies to, e.g. ["asteroid", "anomaly"].
## A contact whose `kind` field matches one of these is researchable as this
## type. An empty list means "match by signature only".
@export var kinds: PackedStringArray = []

@export_group("Parameters")
## Seconds of analysis the subject needs before it is complete. Rare and
## complex subjects take longer.
@export_range(1.0, 900.0, 1.0, "suffix:s") var base_time_seconds: float = 30.0
## Research XP awarded when the subject is analysed for the first time. Zero
## means "no XP, data only". Repeated analysis of the same subject never pays
## out again.
@export_range(0, 100000, 10) var base_xp: int = 50
## Complexity from 1 (trivial) to 5 (exotic). Affects how much the ship's
## condition modifies the time and is used by balance to separate common
## finds from rare ones.
@export_range(1, 5) var complexity: int = 1
## True for rare finds (resonance, distress, unique anomalies). A panel can
## use this to highlight rare subjects.
@export var rare: bool = false

@export_group("Reveal")
## Keys from the object's `world_object_info()` that are revealed once the
## subject is fully analysed. Empty means the object's own description is the
## reward. For phantom signals there is no object, so this is the only way a
## pilot learns what the signal was.
@export var data_keys: PackedStringArray = []


## Does this type answer for a scanner contact with these fields?
func matches(contact: Dictionary) -> bool:
	var sig := String(contact.get("signature", ""))
	var kind := String(contact.get("kind", ""))
	if not signature_ids.is_empty() and signature_ids.has(sig):
		return true
	if not kinds.is_empty() and kinds.has(kind):
		return true
	return false


## The name to show for this type.
func label() -> String:
	return display_name if not display_name.is_empty() else type_id.replace("_", " ").capitalize()


## How much XP this type awards, as configured. Sub-stages may scale this.
func xp_value() -> int:
	return base_xp


## How long this type takes, as configured. Sub-stages may scale this.
func time_value() -> float:
	return base_time_seconds
