extends Resource
class_name SpaceObjectKind
## One population of world content: what it looks like, where it sits, whether it
## is solid.
##
## The generator reads these and nothing else about the world, so a new kind of
## object is a new entry in `SpaceGenerationSettings.kinds` - a wrecked hull, a
## fuel pod, an iceberg - not a change to the streaming code. Two knobs decide the
## whole difference between the two categories the game has:
##
## - `physics` true: candidates are placed as bodies from `body_scene`, at true
##   world coordinates, and the claim rule below keeps their silhouettes apart.
## - `physics` false: candidates are flat `Sprite2D`s on a parallax plane. They
##   cannot be touched, so they may overlap freely and cost no simulation.

@export_group("Identity")
@export var label := "kind"
@export var enabled := true
## Different populations must not agree with each other, so each one hashes with
## its own salt. Two kinds with the same salt land on the same cells.
@export_range(0, 9999) var salt := 1
## Solid bodies, or atmosphere only.
@export var physics := false
## Semantic category used by the world's object interface and diagnostics. Solid
## bodies may override it in their own script; decorative sprites use this value.
@export_enum("asteroid", "debris", "decorative", "environmental_hazard", "interactable") var object_kind := "decorative"

@export_group("Art")
## Folder scanned at runtime; `art_prefix` picks the family out of it. Scanning
## rather than a fixed texture list means dropping one PNG in the folder is the
## whole of adding a variant.
@export var art_dir := "res://assets/asteroids/"
@export var art_prefix := "asteroid_"
## Bodies are instantiated from this scene for `physics` kinds. It must be a
## RigidBody2D carrying a `set_form()` - `scenes/obstacles/Rock.tscn` does.
@export var body_scene: PackedScene
## Glowing decor wants add blending; stone wants to cover the sky behind it.
@export var add_blend := false
## Colour range for the fade between one object and the next. A solid kind uses it
## as a per-object alpha; a decorative kind is background and stays opaque, so its
## depth has to be expressed here in RGB (values below 1 darken).
@export_range(0.0, 4.0, 0.05) var alpha_min := 1.0
@export_range(0.0, 4.0, 0.05) var alpha_max := 1.0
@export_range(-6.2832, 6.2832, 0.01) var rotation_from := -PI
@export_range(-6.2832, 6.2832, 0.01) var rotation_to := PI + 0.0032
## Decor only: how fast a silhouette turns. Rotation stays a function of the view
## point rather than of elapsed time, so a place looks the same however you reach
## it and whatever the frame rate.
@export var spin_max := 0.0
## Used only when no class declares its own pair. A class tint is multiplied into
## this one, so a population can shade everything it makes at once.
@export var tint_from := Color(1, 1, 1, 1)
@export var tint_to := Color(1.22, 1.26, 1.36, 1.0)
## Size range for a kind with no `classes` (decor populations usually have one
## continuous size range instead of named tiers).
@export_range(0.1, 8.0, 0.05) var size_min := 1.0
@export_range(0.1, 8.0, 0.05) var size_max := 1.0
@export_range(0.1, 6.0, 0.01) var size_bias := 1.0
## Named tiers for a physical belt. Empty means one tier spanning the range above.
@export var classes: Array[SpaceSizeClass] = []

@export_group("Scatter")
## Candidate spacing. `max_distance` is the lattice step; `min_distance` only
## decides how far a candidate may drift from its cell centre, so a small
## `min_distance` means a genuinely loose scatter.
@export var min_distance := 90.0
@export var max_distance := 260.0
## Chance a lattice point holds something before the claim rule thins it out.
@export_range(0.0, 1.0, 0.01) var chance := 0.24
## Density is modulated over blocks of this many lattice cells, which is what
## makes room-sized voids instead of an even sprinkle. 0 turns it off.
@export_range(0, 64) var patch_block := 7
## Gate at the emptiest part of the field, as a fraction of `chance`.
@export_range(0.0, 1.0, 0.01) var patch_floor := 0.05
## Chance a candidate is not one object but a knot of them.
@export_range(0.0, 1.0, 0.01) var cluster_chance := 0.0
@export_range(1, 12) var cluster_extra := 4
## Air left between a cluster's centre stone and its satellites, in px.
@export var cluster_gap := 55.0

@export_group("Depth")
## Fraction of the ship's motion this population shows on screen. 1.0 is a body
## at rest in the world; less than 1 puts the objects further away and costs them
## their physics, which is why it is forced back to 1.0 for `physics` kinds.
@export_range(0.0, 1.25, 0.01) var parallax := 1.0

@export_group("Budget")
## Ceiling on how much one chunk may hold, and on how much of the population may
## be alive at once. Both are hard limits: the generator thins the far side of the
## window before it exceeds either.
@export_range(0, 64) var max_per_chunk := 8
@export_range(0, 400) var max_live := 48

## Filled by the field at open, one entry per usable sprite:
## {"tex": Texture2D, "id": String, "file": String, "reach": float, "edge": float}.
## Not exported, so it never lands inside the saved resource.
var art: Array = []
