extends Resource
class_name ResearchProfile

## The whole vocabulary of researchable things, as data.
##
## A profile carries a list of `ResearchType` entries. The research system
## holds one profile; the first type that matches a scanner contact answers
## for it, so a specific type goes above a general one. A future upgrade
## system swaps the profile instead of editing the device.

@export_group("Research Types")
## The types this profile knows about, in priority order. The first one that
## matches a contact answers for it.
@export var types: Array = []


## The type that answers for this scanner contact, or null when nothing does.
## A null is the honest answer for a contact no research type knows about.
func type_for(contact: Dictionary):
	for type in types:
		if type != null and type.matches(contact):
			return type
	return null


## The type with this type_id, or null.
func type(type_id: String):
	for type in types:
		if type != null and type.type_id == type_id:
			return type
	return null


## One line per type, for a debug report or a headless log.
func report() -> Array[String]:
	var lines: Array[String] = [
		"research profile: %d types" % types.size(),
	]
	for type in types:
		if type == null:
			continue
		lines.append("  %-14s %s  %5.1fs  %5d xp  c%d%s" % [
			type.type_id, type.label(),
			type.time_value(), type.xp_value(), type.complexity,
			" rare" if type.rare else "",
		])
	return lines
