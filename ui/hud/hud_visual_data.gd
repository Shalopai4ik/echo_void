extends Resource
class_name HudVisualData

## Visual-only HUD snapshot. Stage 7 will replace the demo resource with a
## controller/model adapter; no scene in this component reads game state.

@export var hull_current := 86.0
@export var hull_maximum := 120.0
@export var energy_current := 74.0
@export var energy_maximum := 100.0
@export var speed := 128.0
@export var speed_unit := "м/с"
## Research XP the flight HUD shows. A demonstration value until stage 7 wires
## the research desk's `xp_gained` signal onto the badge.
@export var research_xp := 340
@export_enum("НОРМА", "ПОВРЕЖДЕНИЕ", "КРИТИЧЕСКОЕ") var ship_state := "НОРМА"
@export var hull_warning_ratio := 0.5
@export var hull_critical_ratio := 0.25
@export var energy_warning_ratio := 0.25
@export var energy_critical_ratio := 0.1
