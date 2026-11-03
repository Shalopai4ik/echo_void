shader_type canvas_item;

// Rolls a flat top-down fighter around its own long axis.
//
// The engine compresses the sprite across the wingspan, which on its own reads as
// a squash. This puts the missing half back: the wing swinging up toward the
// camera catches the key light and the one dropping away falls into shadow, and a
// specular seam slides along the fuselage as the ship goes over.

uniform float bank : hint_range(-1.0, 1.0) = 0.0;
uniform float sheen : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 c = COLOR;
	float y = UV.y;
	// bank > 0 rolls the +Y side away from the camera, so that half darkens. The
	// 3.2 puts the full contrast on the wingtips rather than smearing it evenly
	// over the fuselage, which is where a roll is actually read from.
	float lift = bank * (0.5 - y) * 3.2;
	vec3 tint = mix(vec3(1.0), vec3(1.14, 1.19, 1.28), clamp(lift, 0.0, 1.0));
	tint = mix(tint, vec3(0.34, 0.40, 0.56), clamp(-lift, 0.0, 1.0));

	// the highlight rides the crest of the roll, never the centre line. It scales
	// the paint rather than adding to it: an additive sheen would lift the shadow
	// half further than it lifts the lit half, and the ship would appear to roll
	// harder one way than the other.
	float crest = 0.5 + bank * 0.40;
	float band = smoothstep(0.11, 0.0, abs(y - crest)) * abs(bank);
	vec3 gain = tint * (1.0 + band * 0.55 + sheen * 0.35);
	COLOR = vec4(c.rgb * gain * c.a, c.a);
}
