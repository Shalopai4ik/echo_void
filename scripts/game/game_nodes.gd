class_name GameNodes

## One place that knows how the flight scene's main nodes are found.
##
## Everything here goes through groups, never through paths from the scene
## root, so a test that builds the map by hand and the game itself resolve the
## same nodes. A missing node is null, never an error: a bare test scene simply
## has no hull.

const PLAYER_GROUP := "player"
const SHIP_GROUP := "ship"


## The player's hull.
static func ship(tree: SceneTree) -> Node2D:
	if tree == null:
		return null
	var hull := tree.get_first_node_in_group(PLAYER_GROUP) as Node2D
	if hull == null:
		hull = tree.get_first_node_in_group(SHIP_GROUP) as Node2D
	return hull


## The hull's systems hub (`ShipSystems`).
static func systems(tree: SceneTree) -> Node:
	var hull := ship(tree)
	return hull.get_node_or_null("Systems") if hull != null else null


## One device under the hub by node name: "Scanner", "Research",
## "DecoyLauncher", "SignalLight", "UpgradeDesk", "Slots".
static func device(tree: SceneTree, node_name: String) -> Node:
	var hub := systems(tree)
	return hub.get_node_or_null(node_name) if hub != null else null


## The first node of a group, or null.
static func first(tree: SceneTree, group: String) -> Node:
	return tree.get_first_node_in_group(group) if tree != null else null
