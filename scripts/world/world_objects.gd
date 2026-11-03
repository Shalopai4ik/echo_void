class_name WorldObjects

## What a thing in the world is, said without naming it.
##
## The ship must not learn that "Rock24" is an asteroid, because the world field
## streams bodies in and out of a pool under whatever name the scene gave the first
## one, and a scanner or a hazard added next month is not going to be called anything
## the ship's code has heard of. So every question the ship asks about another object
## goes through this file, and the answers come from two general mechanisms:
##
## - **groups**, which Godot already gives every body and which the object itself
##   joins in its own `_ready()` (`obstacle`, `asteroid`, `debris`, `hazard`,
##   `interactable`, `ship`);
## - **the interface**, which is not an interface in the language sense but a pair of
##   optional methods an object may answer:
##
##       world_object_kind() -> String     # overrides the group reading
##       world_object_info() -> Dictionary # id, title, and whatever else it wants read
##
## An object that implements neither is still describable: it gets a kind from its
## groups and an `unknown_object` when it has none, and the dictionary that comes back
## always has the same keys, so a listener never has to guess what is missing.
##
## Nothing here is a system. There is no registry, no per-category class and no state:
## adding a new kind of thing to the world means joining a group and, if it wants to
## say more about itself than its group says, answering one of the two methods. The
## ship's code does not change, which is the whole requirement of spec 6.

const KIND_ASTEROID := "asteroid"
const KIND_DEBRIS := "debris"
const KIND_HAZARD := "environmental_hazard"
const KIND_UNKNOWN := "unknown_object"
const KIND_INTERACTABLE := "interactable"
const KIND_SHIP := "ship"
## The five kinds the spec lists, plus `ship`: a hull that runs into another hull is a
## case the world will have eventually, and reading it as an asteroid would be a lie.
const KINDS := [KIND_ASTEROID, KIND_DEBRIS, KIND_HAZARD, KIND_UNKNOWN,
		KIND_INTERACTABLE, KIND_SHIP]


## What kind of thing this is. The object's own answer wins over its groups, because an
## object that says what it is has more information than the group it happens to be in
## - a derelict that is both an obstacle and interactable can call itself `interactable`
## and mean it.
static func kind_of(node: Object) -> String:
	if node == null:
		return KIND_UNKNOWN
	if node.has_method("world_object_kind"):
		var declared: String = node.world_object_kind()
		if KINDS.has(declared):
			return declared
	var as_node := node as Node
	if as_node == null:
		return KIND_UNKNOWN
	if as_node.is_in_group(KIND_INTERACTABLE):
		return KIND_INTERACTABLE
	if as_node.is_in_group("debris"):
		return KIND_DEBRIS
	if as_node.is_in_group("hazard") or as_node.is_in_group(KIND_HAZARD):
		return KIND_HAZARD
	if as_node.is_in_group("asteroid") or as_node.is_in_group("obstacle"):
		return KIND_ASTEROID
	if as_node.is_in_group("ship"):
		return KIND_SHIP
	return KIND_UNKNOWN


## Does this object say anything about itself beyond its kind?
static func supports_info(node: Object) -> bool:
	return node != null and node.has_method("world_object_info")


## The one description every listener gets. The keys are always there; the values are
## what could be read. `label` is the node's name, which is a *reading aid* for a human
## looking at a log and never a thing code may compare against.
static func describe(node: Object) -> Dictionary:
	var out := {
		"id": 0,
		"label": "<absent>",
		"kind": KIND_UNKNOWN,
		"title": "",
		"info": {},
		"position": Vector2.INF,
	}
	if node == null:
		return out
	var as_node := node as Node
	out.id = node.get_instance_id()
	if as_node != null:
		out.label = String(as_node.name)
		if as_node is Node2D:
			out.position = (as_node as Node2D).global_position
	out.kind = kind_of(node)
	if supports_info(node):
		var given: Dictionary = node.world_object_info()
		out.info = given
		if given.has("title"):
			out.title = String(given.title)
		if given.has("kind") and KINDS.has(String(given.kind)):
			out.kind = String(given.kind)
	if out.title == "":
		# A body that does not introduce itself is still worth naming in a log, and the
		# only honest name available is the one the scene gave it.
		out.title = String(out.label)
	return out


## A short one-line form for the debug panel and for test output: kind and title, with
## the size only when the object bothered to report one.
static func summarize(description: Dictionary) -> String:
	if description.is_empty() or int(description.id) == 0:
		return "nothing"
	var text := "%s \"%s\"" % [description.kind, description.title]
	var info: Dictionary = description.info
	if info.has("px_scale"):
		text += " x%.2f" % float(info.px_scale)
	elif info.has("radius"):
		text += " r%.0f" % float(info.radius)
	return text
