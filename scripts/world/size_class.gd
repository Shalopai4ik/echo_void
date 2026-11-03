extends Resource
class_name SpaceSizeClass
## One size of thing inside a population: the pebbles, the chunks, the hills.
##
## A kind scatters candidates on one lattice and lets the biggest claim win, so a
## class only has to describe how big it is and which art it may wear. The
## generator never needs to know that a class exists.

@export_group("Identity")
## Only ever read in the inspector: which row of the belt this is.
@export var label := "small"
## How this class takes part in the weighted roll that picks a class per cell.
## It is a share of the whole, not a probability: 70 / 22 / 8 is the default belt.
@export_range(0.0, 1.0, 0.001) var weight := 0.5

@export_group("Scale")
## Sprite scale, and with it the size of the obstacle. The stones in
## `assets/asteroids/` measure 17-79 px, so 1.0 is a chunk and 4.0 is a hill.
@export_range(0.1, 8.0, 0.05) var size_min := 1.0
@export_range(0.1, 8.0, 0.05) var size_max := 1.4
## Pulls the roll inside the range toward the small end: 1 is even, 2 already
## reads as "mostly gravel, occasionally something you have to steer around".
@export_range(0.1, 6.0, 0.01) var size_bias := 1.0

@export_group("Art")
## Only sprites whose longest edge falls in here may be used, which is how a
## pebble never gets drawn wearing a hill's silhouette.
@export var art_min_px := 0.0
@export var art_max_px := 4096.0

@export_group("Look")
## Multiplied into the population's own pair, so neutral here means "inherit".
## Above 1 brightens rather than filters: the stone sheet was cut for a hazy belt
## and reads too dim on the bare black of open space.
@export var tint_from := Color(1, 1, 1, 1)
@export var tint_to := Color(1, 1, 1, 1)
