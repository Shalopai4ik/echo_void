extends RefCounted
class_name WorldChunk

## One cell of the world's streaming grid, and the arithmetic that turns a world
## position into one.
##
## The field stores chunks as plain `Node2D`s keyed by `Vector2i`, which is the
## cheapest thing a per-frame loop can carry. What was missing from that shape is
## the part everything else needs to talk about a chunk without holding its node:
## its identity, its bounds, its generation seed and whether it is loaded right
## now. Those are the four questions the debug overlay, the HUD and the save seam
## ask, and they are all pure functions of the coordinate - so they live here, as
## static helpers, instead of in a second bookkeeping dictionary that would have to
## stay in step with the node map and eventually would not.
##
## A chunk is anchored in *pattern space*: the plane's own fixed coordinate system.
## A population with `parallax = 1.0` (every solid object) has pattern space equal
## to world space, so its chunk bounds are true world rectangles. A distant
## population is shifted on screen as the ship flies, but its chunks still cover a
## fixed region of its own plane - which is what makes a silhouette come back in
## the same place when the pilot returns.
##
## Nothing here allocates per chunk and nothing here is a manager. The manager is
## `EchoWorldField`; this file is the vocabulary it uses.

## The four states the stage asks for, and no more. Generation and release both
## finish inside the frame that started them, so the middle two are transient:
## `GENERATING` is what a wanted-but-not-yet-built chunk reports, and `UNLOADING`
## is what a chunk that has dropped out of the window but is still waiting for its
## turn in the unload budget reports.
enum State { UNLOADED, GENERATING, ACTIVE, UNLOADING }

const HASH := preload("res://scripts/space_background/space_hash.gd")

const STATE_NAMES: Array[String] = ["UNLOADED", "GENERATING", "ACTIVE", "UNLOADING"]


## The chunk a world position falls in, for a grid of `size` px per chunk.
## `floor` rather than `int()`: in the negative half of the world the latter
## truncates toward zero and would fold the two chunks either side of the origin
## into one.
static func key_at(pos: Vector2, size: Vector2) -> Vector2i:
	var s := Vector2(maxf(size.x, 1.0), maxf(size.y, 1.0))
	return Vector2i(int(floor(pos.x / s.x)), int(floor(pos.y / s.y)))


## The world rectangle a chunk covers, in its plane's pattern space.
static func bounds_of(key: Vector2i, size: Vector2) -> Rect2:
	return Rect2(Vector2(key) * size, size)


## The chunk's name in save files, logs and debug text. The plane is part of the
## identity because the game streams several planes, each with its own chunk grid,
## and `3,-2` alone would name a different region on each of them.
static func id_of(key: Vector2i, plane: String) -> String:
	return "%s:%d,%d" % [plane, key.x, key.y]


## Inverse of `id_of`. Returns `""` when the string is not a chunk id, so a caller
## reading a file written by an older build can tell a missing chunk from chunk
## zero.
static func plane_of(id: String) -> String:
	var cut := id.rfind(":")
	if cut <= 0:
		return ""
	var parts := id.substr(cut + 1).split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return ""
	return id.substr(0, cut)


## Inverse of `id_of`: the coordinate half of the name.
static func key_of(id: String) -> Vector2i:
	var cut := id.rfind(":")
	if cut < 0:
		return Vector2i.ZERO
	var parts := id.substr(cut + 1).split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## `ChunkSeed = Hash(world_seed, chunk_x, chunk_y, category)`, in the only form
## Godot gives that is stable across runs: a 64-bit integer mix, never a
## `RandomNumberGenerator` seeded from a clock and never a draw from a shared
## stream. The category is the population's `salt`, so adding a new one in a later
## substage cannot move a single stone of the ones already here.
static func seed_of(key: Vector2i, salt: int, world_seed: int) -> int:
	return HASH.combine(key.x, key.y, salt, world_seed)


static func state_name(state: int) -> String:
	if state < 0 or state >= STATE_NAMES.size():
		return "UNKNOWN"
	return STATE_NAMES[state]


## The four chunks touching this one. Kept here rather than open-coded where a
## later mechanic needs it: a chunk's neighbours are part of the grid's vocabulary,
## not of whoever happens to be asking.
static func neighbours(key: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [key + Vector2i.RIGHT, key + Vector2i.LEFT,
		key + Vector2i.UP, key + Vector2i.DOWN]
	return out