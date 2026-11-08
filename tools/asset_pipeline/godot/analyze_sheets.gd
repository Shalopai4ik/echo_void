extends SceneTree

## One-off analysis of the source sheets under assets/source/: prints the row
## bands and the column segments of the brood sheet, and the connected
## components of the two relic sheets, so cut_sprites.gd can name exact rects.
## Run: godot --headless --path . --script tools/asset_pipeline/godot/analyze_sheets.gd

func _initialize() -> void:
	_brood()
	_relics("res://assets/source/relics_sheet_a.png", true)
	_relics("res://assets/source/relics_sheet_b.png", false)
	quit(0)


func _opaque_brood(c: Color) -> bool:
	return maxf(c.r, maxf(c.g, c.b)) > 0.16


func _brood() -> void:
	var img := Image.load_from_file("res://assets/source/brood_sheet.png")
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	print("brood ", w, "x", h)
	# row profile
	var rows: Array = []
	for y in h:
		var n := 0
		for x in range(0, w, 2):
			if _opaque_brood(img.get_pixel(x, y)):
				n += 1
		rows.append(n)
	var runs := _runs(rows, 2, 4)
	print("row runs: ", runs)
	for r in runs:
		var cols: Array = []
		for x in w:
			var n := 0
			for y in range(r[0], r[1] + 1, 2):
				if _opaque_brood(img.get_pixel(x, y)):
					n += 1
			cols.append(n)
		print("  band ", r, " cols: ", _runs(cols, 1, 6))


func _runs(profile: Array, min_value: int, min_gap: int) -> Array:
	var out: Array = []
	var start := -1
	var gap := 0
	for i in profile.size():
		var on: bool = int(profile[i]) >= min_value
		if on:
			if start < 0:
				start = i
			gap = 0
		elif start >= 0:
			gap += 1
			if gap >= min_gap:
				out.append([start, i - gap])
				start = -1
				gap = 0
	if start >= 0:
		out.append([start, profile.size() - 1])
	return out


func _relic_alpha(c: Color, checker: bool) -> bool:
	if checker:
		var lo := minf(c.r, minf(c.g, c.b))
		var hi := maxf(c.r, maxf(c.g, c.b))
		return not (lo > 0.66 and hi - lo < 0.08)
	return maxf(c.r, maxf(c.g, c.b)) > 0.09 or c.a < 0.5 and false


func _relics(path: String, checker: bool) -> void:
	var img := Image.load_from_file(path)
	print(path, " format ", img.get_format(), " ", img.get_size())
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var step := 2
	var gw := w / step
	var gh := h / step
	var mask := PackedByteArray()
	mask.resize(gw * gh)
	var alpha_min := 1.0
	for gy in gh:
		for gx in gw:
			var c := img.get_pixel(gx * step, gy * step)
			alpha_min = minf(alpha_min, c.a)
			var on := c.a > 0.5 and _relic_alpha(c, checker)
			mask[gy * gw + gx] = 1 if on else 0
	print("  alpha min ", alpha_min)
	var label := PackedInt32Array()
	label.resize(gw * gh)
	var comps: Array = []
	for i in gw * gh:
		if mask[i] == 0 or label[i] != 0:
			continue
		var id := comps.size() + 1
		var stack := [i]
		label[i] = id
		var x0 := gw
		var y0 := gh
		var x1 := 0
		var y1 := 0
		var area := 0
		while not stack.is_empty():
			var p: int = stack.pop_back()
			var px := p % gw
			var py := p / gw
			area += 1
			x0 = mini(x0, px); y0 = mini(y0, py); x1 = maxi(x1, px); y1 = maxi(y1, py)
			for d in [-1, 1, -gw, gw]:
				var q: int = p + d
				if q < 0 or q >= gw * gh:
					continue
				if (d == 1 or d == -1) and q / gw != py:
					continue
				if mask[q] == 1 and label[q] == 0:
					label[q] = id
					stack.append(q)
		comps.append([area, x0 * step, y0 * step, (x1 + 1) * step, (y1 + 1) * step])
	comps.sort_custom(func(a, b): return a[0] > b[0])
	for c in comps:
		if c[0] < 300:
			break
		print("  comp area ", c[0] * step * step, " rect ", c[1], ",", c[2], " - ", c[3], ",", c[4])
