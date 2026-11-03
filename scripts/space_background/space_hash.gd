extends RefCounted
## Deterministic integer hash used by the background system.
##
## Everything the spawner does is derived from hashf(cell, salt) instead of a
## rolling RNG, so the same world coordinates always produce the same content
## no matter when, in which order or at which frame rate they are visited.

const M1: int = 0x2545F4914F6CDD1D
const M2: int = 0x7FF4EA44A06D071
const MASK: int = 0x3FFFFFFF


static func mix(v: int) -> int:
	var x := v
	x = (x ^ (x >> 30)) * M1
	x = (x ^ (x >> 27)) * M2
	return x ^ (x >> 31)


## Combine the world cell, a per-purpose salt and the seed into one integer.
static func combine(cell_x: int, cell_y: int, salt: int, seed: int) -> int:
	var v: int = seed * 0x9E3779B1
	v = mix(v ^ (cell_x * 0xC2B2AE35))
	v = mix(v ^ (cell_y * 0x165667B1))
	v = mix(v ^ (salt * 0x27D4EB2F))
	return v


static func hashf(cell_x: int, cell_y: int, salt: int, seed: int) -> float:
	var v := combine(cell_x, cell_y, salt, seed)
	return float(v & MASK) / float(MASK)


static func hashi(cell_x: int, cell_y: int, salt: int, seed: int, count: int) -> int:
	if count <= 0:
		return 0
	var v := combine(cell_x, cell_y, salt, seed)
	return absi(v % count)


## Smooth-ish value in [0,1] over a coarse block grid, used to build patches of
## different density instead of an even sprinkle.
static func field(cell_x: int, cell_y: int, block: int, salt: int, seed: int) -> float:
	var bx := int(floor(float(cell_x) / float(block)))
	var by := int(floor(float(cell_y) / float(block)))
	var fx := hashf(bx, by, salt, seed)
	var fy := hashf(bx, by + 1, salt, seed)
	var ix := hashf(bx + 1, by, salt, seed)
	var iy := hashf(bx + 1, by + 1, salt, seed)
	var tx := smoothstep(0.0, 1.0, float(cell_x - bx * block) / float(block))
	var ty := smoothstep(0.0, 1.0, float(cell_y - by * block) / float(block))
	return lerpf(lerpf(fx, ix, tx), lerpf(fy, iy, tx), ty)


static func smoothstep(from: float, to: float, v: float) -> float:
	var s := clampf((v - from) / maxf(to - from, 0.000001), 0.0, 1.0)
	return s * s * (3.0 - 2.0 * s)
