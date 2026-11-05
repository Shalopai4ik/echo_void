extends RefCounted
class_name ChunkStateStore

## What the world remembers about a chunk after the chunk itself is gone.
##
## The generator is deterministic, so a region that has been flown out of is
## rebuilt in exactly the state it was generated in - but "generated" is not the
## same as "left". A stone that was broken, a wreck that was scanned, a pod that
## was emptied: none of that is in the seed, and all of it has to survive the
## chunk being unloaded. So the two are kept apart on purpose:
##
## - the plan, which is a pure function of the coordinate and the seed and is
##   never stored at all;
## - the deltas, which are only what somebody actually changed, and are stored
##   here.
##
## A chunk that nobody has touched costs nothing: records are created on the first
## write, not on generation. That is why an endless flight can afford to remember
## everything the pilot changed for as long as the session lives, and why
## `to_dict()` is small enough to hand to a save file later.
##
## Nothing here creates nodes or knows what a chunk contains. It is a dictionary
## with a version number and a set of names for the two kinds of state the field
## applies at build time (`removed`, `transform`) or hands back to the object that
## asked to be remembered.

const VERSION := 1
## The keys the field understands itself, in every object's state dictionary.
## Anything else in there belongs to the object.
const KEY_REMOVED := "removed"
const KEY_TRANSFORM := "transform"

## Packed name ("plane:x,y") -> {"data": Dictionary, "objects": Dictionary}.
## `data` is chunk-level (a scan of the whole region), `objects` is keyed by the
## stable item id the generator gives each object.
var _chunks := {}


# ------------------------------------------------------------------- reading ----

func has_chunk(id: String) -> bool:
	return _chunks.has(id)


func chunk_count() -> int:
	return _chunks.size()


## How many individual objects are carrying state, across every chunk.
func object_total() -> int:
	var n := 0
	for id in _chunks:
		n += (_chunks[id]["objects"] as Dictionary).size()
	return n


func ids() -> Array[String]:
	var out: Array[String] = []
	for id in _chunks:
		out.append(String(id))
	out.sort()
	return out


## Chunk-level state, as a copy: a caller may read it, but only `set_chunk_data`
## changes what the store will hand out next time.
func chunk_data(id: String) -> Dictionary:
	if not _chunks.has(id):
		return {}
	return (_chunks[id]["data"] as Dictionary).duplicate(true)


func chunk_value(id: String, key: String, fallback: Variant = null) -> Variant:
	if not _chunks.has(id):
		return fallback
	var data: Dictionary = _chunks[id]["data"]
	return data.get(key, fallback)


## One object's state. Empty when the object has never been touched - the same
## answer as "no state", which is what lets the field treat both identically.
func object_state(id: String, item_id: String) -> Dictionary:
	if not _chunks.has(id):
		return {}
	var objects: Dictionary = _chunks[id]["objects"]
	if not objects.has(item_id):
		return {}
	return (objects[item_id] as Dictionary).duplicate(true)


func has_object(id: String, item_id: String) -> bool:
	return not object_state(id, item_id).is_empty()


func object_ids(id: String) -> Array[String]:
	var out: Array[String] = []
	if not _chunks.has(id):
		return out
	for item_id in _chunks[id]["objects"]:
		out.append(String(item_id))
	out.sort()
	return out


## Would this item be skipped when its chunk is rebuilt?
func is_removed(id: String, item_id: String) -> bool:
	return bool(object_state(id, item_id).get(KEY_REMOVED, false))


# ------------------------------------------------------------------- writing ----

## Replace a chunk's own state. An empty dictionary erases it, so "back to the
## generated default" is one call and not a special case.
func set_chunk_data(id: String, data: Dictionary) -> void:
	if data.is_empty():
		if _chunks.has(id):
			_chunks[id]["data"] = {}
			_prune(id)
		return
	_record(id)["data"] = data.duplicate(true)


func set_chunk_value(id: String, key: String, value: Variant) -> void:
	var data := chunk_data(id)
	if value == null:
		data.erase(key)
	else:
		data[key] = value
	set_chunk_data(id, data)


## Store what an object reported about itself. Empty erases, which is how an
## object says "I am back to default" without the store keeping a tombstone.
func set_object_state(id: String, item_id: String, state: Dictionary) -> void:
	if item_id.is_empty():
		return
	if state.is_empty():
		if _chunks.has(id):
			(_chunks[id]["objects"] as Dictionary).erase(item_id)
			_prune(id)
		return
	(_record(id)["objects"] as Dictionary)[item_id] = state.duplicate(true)


## The universal edit: this object is gone and must not be rebuilt.
func remove_object(id: String, item_id: String) -> void:
	var state := object_state(id, item_id)
	state[KEY_REMOVED] = true
	set_object_state(id, item_id, state)


## The opposite edit, for a mechanic that puts something back.
func restore_object(id: String, item_id: String) -> void:
	var state := object_state(id, item_id)
	if state.is_empty():
		return
	state.erase(KEY_REMOVED)
	set_object_state(id, item_id, state)


## Drop everything remembered about one chunk. For a region that is being
## re-authored, not for one that is merely out of view.
func forget_chunk(id: String) -> void:
	_chunks.erase(id)


func clear() -> void:
	_chunks.clear()


# ------------------------------------------------------------------ save seam ----

## A plain, JSON-safe-enough picture of the store. `duplicate(true)` on the way
## out, so a serializer walking this cannot write through into live state.
func to_dict() -> Dictionary:
	var chunks := {}
	for id in _chunks:
		chunks[id] = (_chunks[id] as Dictionary).duplicate(true)
	return {"version": VERSION, "chunks": chunks}


## Read back what `to_dict()` wrote. Returns false for a payload this build does
## not understand, and leaves the store empty in that case rather than half-filled:
## a save that cannot be trusted is worse than a world that is merely new.
func from_dict(data: Dictionary) -> bool:
	clear()
	if int(data.get("version", 0)) != VERSION:
		return false
	var chunks: Variant = data.get("chunks", {})
	if not chunks is Dictionary:
		return false
	for id in (chunks as Dictionary):
		var rec: Variant = (chunks as Dictionary)[id]
		if not rec is Dictionary:
			continue
		var raw_data: Variant = (rec as Dictionary).get("data", {})
		var raw_objects: Variant = (rec as Dictionary).get("objects", {})
		var clean := {
			"data": (raw_data as Dictionary).duplicate(true) if raw_data is Dictionary else {},
			"objects": (raw_objects as Dictionary).duplicate(true) if raw_objects is Dictionary else {},
		}
		if (clean["data"] as Dictionary).is_empty() \
				and (clean["objects"] as Dictionary).is_empty():
			continue
		_chunks[String(id)] = clean
	return true


# -------------------------------------------------------------------- private ----

func _record(id: String) -> Dictionary:
	if not _chunks.has(id):
		_chunks[id] = {"data": {}, "objects": {}}
	return _chunks[id]


## A record with nothing left in it is not a record. Keeping empty shells would
## make `chunk_count()` grow with every chunk the pilot ever scanned and then
## undid.
func _prune(id: String) -> void:
	if not _chunks.has(id):
		return
	var rec: Dictionary = _chunks[id]
	if (rec["data"] as Dictionary).is_empty() and (rec["objects"] as Dictionary).is_empty():
		_chunks.erase(id)