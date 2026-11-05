extends Node
class_name ShipEnergyClock

## The only per-frame piece of the ship's internal layer.
##
## `ShipSystems` is deliberately without `_process`/`_physics_process` (stage 4.1
## asserts that, and it is what keeps an idle hull free of per-frame work). A reserve
## that drains and regenerates needs a clock, so the clock is its own node with one
## job: hand the physics delta to `ShipEnergySystem.advance()` and nothing else. It
## owns no state, decides nothing, and a hull that removes it simply gets a reserve
## that only moves when somebody calls `advance()` by hand.
##
## It is created by the hub in `_build()` and named `EnergyClock`, so a test or a
## debug panel can find it without a second registration list.

## The tank to step. Assigned by the hub through `attach()`; null-safe here so a node
## dropped into a scene by hand does not crash before it is wired.
var energy: ShipEnergySystem


func attach(system: ShipEnergySystem) -> void:
	energy = system
	set_physics_process(energy != null)


func _ready() -> void:
	set_physics_process(energy != null)


func _physics_process(delta: float) -> void:
	if energy != null:
		energy.advance(delta)