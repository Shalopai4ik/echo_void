extends Node2D
class_name EchoSpaceSpawner
## Generation parameters for the infinite background, and the only place that
## decides what appears where.
##
## Every value a band needs is derived from the integer cell coordinate through
## SpaceHash, so nothing is drawn from a rolling RNG. Two ships that reach the
## same cell see the same rocks, and a 30 fps machine generates exactly what a
## 144 fps machine generates.
##
## Spacing: `max_distance` becomes the cell size and `min_distance` shrinks the
## jitter, so any two neighbours in adjacent cells are guaranteed to be at least
## min_distance apart and at most about max_distance apart.

@export_group("Seed")
## Same seed, same universe. Change it to get a different region of space.
@export var world_seed: int = 20261029
@export_range(0, 1) var randomize_seed_on_start: float = 0.0

@export_group("Generation")
## How many cells beyond the screen edge are prepared in advance.
@export_range(0.0, 6.0, 0.05) var chunks_ahead: float = 1.5
## Hard ceiling on live decorative nodes across all bands.
@export_range(0, 600) var max_active_objects: int = 520

@export_subgroup("Stars and dust")
@export_range(0.0, 1.0, 0.01) var star_density: float = 0.62
@export var star_min_distance: float = 34.0
@export var star_max_distance: float = 96.0
@export var star_size_min: float = 0.35
@export var star_size_max: float = 1.15
@export_range(0.0, 1.0, 0.01) var star_twinkle: float = 0.35
@export_range(0.0, 0.6, 0.01) var star_cluster_chance: float = 0.10

@export_subgroup("Far asteroids and debris")
@export_range(0.0, 1.0, 0.01) var mid_density: float = 0.55
@export var mid_min_distance: float = 170.0
@export var mid_max_distance: float = 290.0
@export var mid_size_min: float = 0.45
@export var mid_size_max: float = 1.05
@export var mid_spin: float = 0.06
@export var mid_drift: float = 10.0
@export_range(0.0, 0.6, 0.01) var mid_cluster_chance: float = 0.16
@export var midground_factor: float = 0.42

@export_subgroup("Near asteroids")
@export_range(0.0, 1.0, 0.01) var near_density: float = 0.22
@export var near_min_distance: float = 420.0
@export var near_max_distance: float = 760.0
@export var near_size_min: float = 0.7
@export var near_size_max: float = 1.5
@export var near_spin: float = 0.13
@export var near_drift: float = 16.0
@export_range(0.0, 0.6, 0.01) var near_cluster_chance: float = 0.08
@export var near_factor: float = 0.88

@export_subgroup("Nebula patches")
@export_range(0.0, 1.0, 0.01) var nebula_density: float = 0.5
@export var nebula_min_distance: float = 700.0
@export var nebula_max_distance: float = 1500.0

@export_subgroup("Rare silhouettes and anomalies")
@export_range(0.0, 1.0, 0.01) var anomaly_density: float = 0.16
@export var anomaly_min_distance: float = 2600.0
@export var anomaly_max_distance: float = 5200.0
@export var anomaly_factor: float = 0.30

@export_subgroup("Per-band node caps")
@export_range(0, 200) var max_nebula: int = 40
@export_range(0, 200) var max_stars: int = 200
@export_range(0, 200) var max_mid: int = 100
@export_range(0, 200) var max_near: int = 44
@export_range(0, 200) var max_anomaly: int = 6


func _ready() -> void:
	if randomize_seed_on_start > 0.0:
		world_seed = int(Time.get_unix_time_from_system()) % 1000000


func set_seed(value: int) -> void:
	world_seed = value


## Cell size + jitter for a min/max distance pair.
func _grid(min_d: float, max_d: float) -> Dictionary:
	var cell := maxf(max_d, min_d + 1.0)
	return {
		"cell_size": Vector2(cell, cell * 0.78),
		"jitter": clampf((cell - min_d) / cell, 0.0, 1.0),
	}


## Everything the root node needs to build one band.
func params_for(kind: String) -> Dictionary:
	var out := {}
	match kind:
		"stars":
			out = _grid(star_min_distance, star_max_distance)
			out["density"] = star_density
			out["max_per_cell"] = 2
			out["cluster_chance"] = star_cluster_chance
			out["cluster_extra"] = 4
			out["size_range"] = Vector2(star_size_min, star_size_max)
			out["twinkle"] = star_twinkle
			out["max_nodes"] = max_stars
		"midground":
			out = _grid(mid_min_distance, mid_max_distance)
			out["density"] = mid_density
			out["max_per_cell"] = 2
			out["cluster_chance"] = mid_cluster_chance
			out["cluster_extra"] = 4
			out["size_range"] = Vector2(mid_size_min, mid_size_max)
			out["spin_range"] = Vector2(-mid_spin, mid_spin)
			out["drift_amp"] = mid_drift
			out["max_nodes"] = max_mid
			out["scroll_factor"] = midground_factor
		"near":
			out = _grid(near_min_distance, near_max_distance)
			out["density"] = near_density
			out["max_per_cell"] = 1
			out["cluster_chance"] = near_cluster_chance
			out["cluster_extra"] = 2
			out["size_range"] = Vector2(near_size_min, near_size_max)
			out["spin_range"] = Vector2(-near_spin, near_spin)
			out["drift_amp"] = near_drift
			out["max_nodes"] = max_near
			out["scroll_factor"] = near_factor
		"nebula":
			out = _grid(nebula_min_distance, nebula_max_distance)
			out["density"] = nebula_density
			out["max_nodes"] = max_nebula
		"anomaly":
			out = _grid(anomaly_min_distance, anomaly_max_distance)
			out["density"] = anomaly_density
			out["max_nodes"] = max_anomaly
			out["scroll_factor"] = anomaly_factor
		_:
			out = {"cell_size": Vector2(512, 512), "jitter": 1.0}
	out["seed"] = world_seed
	out["margin_scale"] = chunks_ahead
	return out


## Total budget shared between bands, so raising density cannot melt a weak GPU.
func budget() -> int:
	return max_active_objects
