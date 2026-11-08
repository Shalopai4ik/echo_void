extends SceneTree
## Frame-time profile of real flight (needs a GPU, no --headless): the ship
## flies under thrust and boost through the belt for 25 s while every frame's
## wall time and the engine's process/physics times are recorded. Prints the
## percentiles and the worst frames with what the world was doing.
## Run: godot --path . --script tests/experiments/_frame_profile.gd

var _times: Array[float] = []
var _worst: Array = []
var _last := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var map: Node = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	var ship: RigidBody2D = map.get_node("Ship")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("off="):
			for p in arg.substr(4).split(","):
				var n := map.get_node_or_null(p)
				if n != null:
					n.process_mode = Node.PROCESS_MODE_DISABLED
					if n is CanvasItem: (n as CanvasItem).visible = false
					if n is CanvasLayer: (n as CanvasLayer).visible = false
					print("off ", p)
	ship.collision_mask = 0
	for i in 60:
		await process_frame
	_last = Time.get_ticks_usec()
	Input.action_press("thrust_forward")
	var frames := 0
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 25000:
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - _last) / 1000.0
		_last = now
		frames += 1
		_times.append(dt)
		if frames % 120 == 0:
			ship.rotation += 0.6
		if frames == 300:
			Input.action_press("boost")
		if dt > 22.0:
			_worst.append([dt, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				ship.call("speed")])
	Input.action_release("thrust_forward")
	Input.action_release("boost")
	var sorted := _times.duplicate()
	sorted.sort()
	var n := sorted.size()
	print("frames=%d avg=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f  >22ms: %d  >33ms: %d" % [
		n, _avg(sorted), sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[n - 1],
		sorted.filter(func(v): return v > 22.0).size(), sorted.filter(func(v): return v > 33.0).size()])
	_worst.sort_custom(func(a, b): return a[0] > b[0])
	for w in _worst.slice(0, 12):
		print("  spike %.1fms  process=%.1f physics=%.1f nodes=%d speed=%.0f" % w)
	print("draw calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		" objects=", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		" nodes=", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	quit(0)


func _avg(a: Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(a.size(), 1)
