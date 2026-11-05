extends Resource
class_name SpaceGenerationSettings
## Every number that decides what the endless space is made of.
##
## This is the tuning surface for the whole environment: one resource, edited in
## the inspector, no code. `SpaceObjectKind` entries say what each population
## looks like and how thick it is; what is here is the frame around them - the
## seed the world is hashed from, the size of a streaming chunk, how far ahead of
## the ship chunks are prepared, and the ceilings that keep a long flight cheap.
##
## The knobs that multiply a kind's own number are deliberately master values:
## turning `rock_density_scale` down thins every belt at once without touching a
## single population, which is what a difficulty pass needs.

@export_group("Seed")
## Same seed, same universe. Every object's size, shape, tint and turn is a hash
## of its lattice cell and this number, so a region you have flown out of is
## rebuilt exactly as it was - and one flight second later it is still the same.
@export var world_seed: int = 20261102
## Replace the seed with the clock on start. For taking a look at a new universe
## without editing anything; leave at 0 for a world you can return to.
@export_range(0.0, 1.0, 1.0) var randomize_on_start: float = 0.0

@export_group("Chunks")
## One side of a streaming chunk in world pixels. Bigger chunks means fewer
## bookkeeping passes and more objects built in one go; smaller means a smoother
## build cost per frame.
@export_range(128.0, 4096.0, 16.0, "suffix:px") var chunk_size: float = 1024.0
## How much of a chunk beyond the screen edge is kept loaded. 1 is one chunk of
## runway, which is what keeps an object from ever being born in front of the bow.
@export_range(0.0, 6.0, 0.1) var look_ahead_chunks: float = 1.5
## A second ring, this far in chunk widths beyond `look_ahead_chunks`, that is
## only built once the visible window and the load ring have been satisfied and
## the frame still has budget left. This is what turns "the rock appears when the
## screen reaches it" into "the rock was already there": a boost run crosses the
## load ring in a fraction of a second, but the preload ring is a whole extra
## chunk of runway underneath it.
@export_range(0.0, 6.0, 0.1) var preload_chunks: float = 1.0
## Extra room, in chunk widths, where a chunk is dropped again. The gap between
## the two margins is the hysteresis that stops a chunk on the boundary from being
## rebuilt every frame by a ship that is hovering.
@export_range(0.0, 6.0, 0.1) var drop_behind_chunks: float = 3.25
## Objects a single frame may create. Generation is a queue drained in order of
## distance from the ship, so this only ever delays the far edge of the window -
## it cannot make a rock appear off the bow.
@export_range(1, 200) var build_per_frame: int = 24
## Chunks a single frame may start, independently of the object count. One chunk
## of a sparse population is one object, so the object budget alone would let a
## frame start twenty chunks of planning; this is the ceiling that keeps the
## planning itself off the frame.
@export_range(1, 64) var max_chunk_generations_per_frame: int = 6
## Chunks a single frame may hand back to the pool. A teleport can leave twenty
## chunks behind at once, and freeing twenty scene subtrees in one frame is a
## hitch; the rest keep their contents for another frame. The plane with the
## biggest backlog goes first and, within it, the chunk farthest from the ship -
## the near end of a trail is the part that can still come back on screen.
@export_range(1, 256) var max_chunk_unloads_per_frame: int = 8
## Microseconds of generating a single frame is allowed to spend, counted inside
## the field rather than in the whole frame. The object cap above cannot bound the
## cost of one chunk, because a chunk is planned in one go; this one can, by
## starting fewer of them per frame.
@export_range(100.0, 12000.0, 50.0, "suffix:us") var build_microseconds: float = 2200.0

@export_group("State")
## Keep what an unloaded chunk's objects report about themselves, so a broken
## stone stays broken and a scanned wreck stays scanned when the pilot comes
## back. Only chunks somebody has actually changed cost anything: the generated
## content itself is never stored, because the seed regenerates it.
@export var keep_chunk_state: bool = true

@export_group("Density")
## Multiplies every physical population's `chance` and ceilings.
@export_range(0.0, 3.0, 0.01) var rock_density_scale: float = 1.0
## Multiplies every decorative population's `chance` and ceilings.
@export_range(0.0, 3.0, 0.01) var decor_density_scale: float = 1.0
## The ship's own breathing room at the start of the game: no stone of any kind
## inside this radius of the map origin. Deliberately a fixed place in the world
## rather than a distance from the hull. A moving exclusion zone would make the
## belt depend on the route the ship took to get here, which is the one property
## the whole generator is built to keep - and it is not needed: chunks are made
## a chunk and a half ahead of the bow, so nothing is ever born where the ship
## already is, and if the pilot somehow outruns the build queue the solver simply
## shoves the hull out, as it does with any stone.
@export_range(0.0, 4000.0, 10.0, "suffix:px") var spawn_clear_radius: float = 760.0

@export_group("Populations")
## What lives in the space. Solid ones need `body_scene`; the rest are atmosphere.
@export var kinds: Array[SpaceObjectKind] = []


func seeded() -> SpaceGenerationSettings:
	if randomize_on_start > 0.0:
		world_seed = int(Time.get_unix_time_from_system()) % 100000000
	return self
