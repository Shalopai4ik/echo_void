extends SceneTree

## Cuts the game sprites out of the source sheets in assets/source/ (copied
## from the art folder `pictures/`).
##
##   brood_sheet.png     -> assets/threats/brood/<anim>_<n>.png   (320x320 frames)
##   relics_sheet_a.png  -> assets/relics/<name>.png  (baked checkerboard keyed out)
##   relics_sheet_b.png  -> assets/relics/<name>.png  (real alpha)
##
## Deterministic: the rects below were measured by analyze_sheets.gd, and the
## same sheet always produces the same PNGs.
## Run: godot --headless --path . --script tools/asset_pipeline/godot/cut_sprites.gd

const BROOD_OUT := "res://assets/threats/brood/"
const RELIC_OUT := "res://assets/relics/"
const FRAME := 320

## [anim, band_y0, band_y1, [[x0, x1], ...]]
const BROOD := [
	["idle", 70, 240, [[30, 190], [224, 377], [409, 560], [592, 744]]],
	["move", 70, 240, [[788, 961], [982, 1143], [1169, 1309], [1346, 1486]]],
	["attack", 392, 630, [[26, 193], [221, 387], [404, 564], [583, 794]]],
	["hit", 392, 630, [[820, 973], [1002, 1148], [1170, 1315], [1356, 1514]]],
	["death", 700, 1000, [[18, 205], [215, 405], [410, 608], [632, 837], [868, 1132], [1160, 1513]]],
]

## [sheet, name, x0, y0, x1, y1]
const RELICS := [
	["a", "hull_section_1", 42, 50, 352, 502],
	["a", "hull_section_2", 1296, 104, 1576, 516],
	["a", "hull_section_3", 340, 110, 560, 574],
	["a", "hull_section_4", 610, 88, 954, 510],
	["a", "hull_section_5", 826, 102, 1106, 396],
	["a", "hull_section_6", 1128, 100, 1302, 448],
	["a", "hull_section_7", 28, 564, 262, 758],
	["a", "ring_segment_1", 1588, 90, 1910, 516],
	["a", "ring_segment_2", 1086, 580, 1258, 738],
	["a", "wreck_fragment_1", 466, 444, 656, 682],
	["a", "wreck_fragment_2", 610, 562, 788, 760],
	["a", "wreck_fragment_3", 862, 508, 1038, 760],
	["a", "wreck_fragment_4", 1678, 588, 1920, 760],
	["a", "wreck_fragment_5", 1320, 592, 1480, 754],
	["a", "wreck_fragment_6", 302, 618, 460, 758],
	["b", "monolith_rock", 974, 28, 1352, 370],
	["b", "alien_orb", 18, 588, 316, 886],
	["b", "signal_buoy_1", 1384, 18, 1650, 362],
	["b", "signal_buoy_2", 1216, 640, 1472, 912],
	["b", "ring_segment_3", 1428, 408, 1644, 770],
	["b", "ring_segment_4", 558, 72, 888, 376],
	["b", "ring_segment_5", 354, 700, 504, 916],
	["b", "hull_section_8", 832, 360, 1178, 602],
	["b", "hull_section_9", 94, 24, 520, 198],
	["b", "hull_section_10", 344, 338, 712, 524],
	["b", "crystal_1", 1130, 782, 1288, 916],
	["b", "crystal_2", 1240, 378, 1414, 536],
	["b", "crystal_3", 270, 504, 454, 664],
	["b", "wreck_fragment_7", 614, 678, 822, 826],
	["b", "wreck_fragment_8", 20, 352, 254, 514],
	["b", "wreck_fragment_9", 812, 610, 1020, 874],
]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(BROOD_OUT)
	DirAccess.make_dir_recursive_absolute(RELIC_OUT)
	_cut_brood()
	_cut_relics()
	quit(0)


# ----------------------------------------------------------------- the brood ---

func _brood_alpha(c: Color) -> float:
	var hi := maxf(c.r, maxf(c.g, c.b))
	return clampf((hi - 0.055) / 0.2, 0.0, 1.0)


func _cut_brood() -> void:
	var sheet := Image.load_from_file("res://assets/source/brood_sheet.png")
	sheet.convert(Image.FORMAT_RGBA8)
	for anim in BROOD:
		var name: String = anim[0]
		var y0: int = anim[1]
		var y1: int = anim[2]
		var segs: Array = anim[3]
		for i in segs.size():
			var x0: int = segs[i][0]
			var x1: int = segs[i][1]
			# body centre: the bbox of the first 175 columns, so the attack
			# beam does not drag the body off the frame centre
			var bx1 := mini(x1, x0 + 175)
			var cy0 := y1
			var cy1 := y0
			for y in range(y0, y1 + 1):
				for x in range(x0, bx1 + 1):
					if _brood_alpha(sheet.get_pixel(x, y)) > 0.5:
						cy0 = mini(cy0, y)
						cy1 = maxi(cy1, y)
			var cx := (x0 + bx1) / 2
			var cy := (cy0 + cy1) / 2 if cy1 >= cy0 else (y0 + y1) / 2
			var out := Image.create(FRAME, FRAME, false, Image.FORMAT_RGBA8)
			out.fill(Color(0, 0, 0, 0))
			for y in range(y0, y1 + 1):
				var oy := y - cy + FRAME / 2
				if oy < 0 or oy >= FRAME:
					continue
				for x in range(x0, x1 + 1):
					var ox := x - cx + FRAME / 2
					if ox < 0 or ox >= FRAME:
						continue
					var c := sheet.get_pixel(x, y)
					var a := _brood_alpha(c)
					if a <= 0.0:
						continue
					out.set_pixel(ox, oy, Color(c.r, c.g, c.b, a))
			var file := "%s%s_%d.png" % [BROOD_OUT, name, i]
			out.save_png(file)
			print("saved ", file)


# ---------------------------------------------------------------- the relics ---

func _is_checker(c: Color) -> bool:
	var lo := minf(c.r, minf(c.g, c.b))
	var hi := maxf(c.r, maxf(c.g, c.b))
	return lo > 0.62 and hi - lo < 0.09


func _cut_relics() -> void:
	var sheets := {
		"a": Image.load_from_file("res://assets/source/relics_sheet_a.png"),
		"b": Image.load_from_file("res://assets/source/relics_sheet_b.png"),
	}
	for key in sheets:
		(sheets[key] as Image).convert(Image.FORMAT_RGBA8)
	for r in RELICS:
		var sheet: Image = sheets[r[0]]
		var checker: bool = r[0] == "a"
		var x0: int = r[2]
		var y0: int = r[3]
		var x1: int = mini(r[4], sheet.get_width() - 1)
		var y1: int = mini(r[5], sheet.get_height() - 1)
		var w := x1 - x0 + 1
		var h := y1 - y0 + 1
		# solid mask inside the rect
		var solid := PackedByteArray()
		solid.resize(w * h)
		for y in h:
			for x in w:
				var c := sheet.get_pixel(x0 + x, y0 + y)
				var on := c.a > 0.35
				if checker and _is_checker(c):
					on = false
				solid[y * w + x] = 1 if on else 0
		# keep the largest component and the pieces close to it: a neighbour's
		# corner that pokes into the rect is not part of this relic
		var keep := _main_component(solid, w, h)
		if checker:
			# the baked checkerboard bleeds into the outermost ring of pixels:
			# shave it off so no light fringe is left around the dark metal
			keep = _erode(keep, w, h)
		var pad := 6
		var out := Image.create(w + pad * 2, h + pad * 2, false, Image.FORMAT_RGBA8)
		out.fill(Color(0, 0, 0, 0))
		for y in h:
			for x in w:
				if keep[y * w + x] == 0:
					continue
				var c := sheet.get_pixel(x0 + x, y0 + y)
				var a := c.a
				if checker:
					# soften the halo the baked checkerboard leaves on the rim
					var edge := _touches_background(keep, w, h, x, y)
					var lo := minf(c.r, minf(c.g, c.b))
					if edge and lo > 0.4:
						continue
					if edge:
						a = 0.75
				out.set_pixel(x + pad, y + pad, Color(c.r, c.g, c.b, a))
		var file := "%s%s.png" % [RELIC_OUT, r[1]]
		out.save_png(file)
		print("saved ", file, " ", out.get_size())


func _touches_background(mask: PackedByteArray, w: int, h: int, x: int, y: int) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var ny: int = y + d.y
		if nx < 0 or ny < 0 or nx >= w or ny >= h:
			return true
		if mask[ny * w + nx] == 0:
			return true
	return false


## The biggest connected blob, plus every blob whose box sits inside the big
## one's box grown by 12 %: loose bolts orbiting a wreck stay with it.
func _main_component(solid: PackedByteArray, w: int, h: int) -> PackedByteArray:
	var label := PackedInt32Array()
	label.resize(w * h)
	var boxes: Array = []
	for i in w * h:
		if solid[i] == 0 or label[i] != 0:
			continue
		var id := boxes.size() + 1
		var stack: Array[int] = [i]
		label[i] = id
		var bx0 := w
		var by0 := h
		var bx1 := 0
		var by1 := 0
		var area := 0
		while not stack.is_empty():
			var p: int = stack.pop_back()
			var px := p % w
			var py := p / w
			area += 1
			bx0 = mini(bx0, px); by0 = mini(by0, py)
			bx1 = maxi(bx1, px); by1 = maxi(by1, py)
			if px > 0 and solid[p - 1] == 1 and label[p - 1] == 0:
				label[p - 1] = id; stack.append(p - 1)
			if px < w - 1 and solid[p + 1] == 1 and label[p + 1] == 0:
				label[p + 1] = id; stack.append(p + 1)
			if py > 0 and solid[p - w] == 1 and label[p - w] == 0:
				label[p - w] = id; stack.append(p - w)
			if py < h - 1 and solid[p + w] == 1 and label[p + w] == 0:
				label[p + w] = id; stack.append(p + w)
		boxes.append({"id": id, "area": area, "rect": Rect2i(bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1)})
	var keep := PackedByteArray()
	keep.resize(w * h)
	if boxes.is_empty():
		return keep
	boxes.sort_custom(func(a, b): return a["area"] > b["area"])
	var main: Rect2i = boxes[0]["rect"]
	var grow := Rect2i(main.position - main.size * 6 / 100, main.size + main.size * 12 / 100)
	var ids := {}
	for b in boxes:
		var rect: Rect2i = b["rect"]
		if b == boxes[0] or (grow.encloses(rect) and int(b["area"]) > 12):
			ids[int(b["id"])] = true
	for i in w * h:
		if ids.has(label[i]):
			keep[i] = 1
	return keep


## Drop every kept pixel that touches the background (one-pixel erosion).
func _erode(mask: PackedByteArray, w: int, h: int) -> PackedByteArray:
	var out := mask.duplicate()
	for y in h:
		for x in w:
			if mask[y * w + x] == 1 and _touches_background(mask, w, h, x, y):
				out[y * w + x] = 0
	return out
