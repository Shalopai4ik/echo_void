shader_type canvas_item;

// The whole planet in one pass: banded atmosphere, terminator, haze on the limb,
// and the ring system around it.
//
// It is a shader and not a painting because of scale. The disc is several
// thousand world pixels across and mostly sits off screen, so a bitmap of it
// would be a texture bigger than the game window, resampled to a sliver. Drawn
// from a quad, the only pixels that cost anything are the ones the camera can
// actually see, and the planet can be any size the designer types in.
//
// The geometry is a sphere seen face on, which is what a top-down view of a gas
// giant gives you: q is the surface point in disc radii, z closes it into a
// hemisphere, and every lighting term below is read off that normal.

uniform vec2 disc_center = vec2(0.5, 0.5);
uniform float disc_radius : hint_range(0.01, 0.5) = 0.34;

// surface palette
uniform vec3 night_color : source_color = vec3(0.004, 0.010, 0.020);
uniform vec3 band_dark : source_color = vec3(0.030, 0.052, 0.082);
uniform vec3 band_light : source_color = vec3(0.115, 0.150, 0.185);
uniform vec3 band_warm : source_color = vec3(0.175, 0.130, 0.085);
uniform vec3 haze_color : source_color = vec3(0.28, 0.50, 0.70);
uniform float light_angle = 2.35;
uniform float band_count : hint_range(2.0, 26.0) = 16.0;
uniform float turbulence : hint_range(0.0, 2.0) = 0.9;
uniform float cloud_amount : hint_range(0.0, 1.0) = 0.42;
uniform float cloud_drift = 0.05;
uniform float time = 0.0;
uniform float limb_darkening : hint_range(0.0, 1.0) = 0.6;
uniform float atmosphere : hint_range(0.0, 0.3) = 0.022;

// rings
uniform bool show_rings = true;
uniform float ring_inner : hint_range(1.02, 4.0) = 1.02;
uniform float ring_outer : hint_range(1.05, 6.0) = 1.06;
uniform float ring_squash : hint_range(0.08, 1.0) = 1.0;
uniform float ring_density : hint_range(0.0, 1.0) = 0.7;
uniform vec3 ring_color : source_color = vec3(0.30, 0.33, 0.38);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 5; i++) {
		sum += amp * vnoise(p);
		p = p * 2.03 + vec2(11.0, 7.0);
		amp *= 0.5;
	}
	return sum;
}

void fragment() {
	vec2 q = (UV - disc_center) / disc_radius;
	float r = length(q);
	// The star sits in the plane the camera looks along, so the terminator is the
	// great circle the frame can actually show the edge of: the near limb catches
	// light and the body of the planet falls away into its own night.
	vec3 L = normalize(vec3(cos(light_angle), sin(light_angle), 0.0));
	vec3 col = vec3(0.0);
	float alpha = 0.0;

	// A canvas_item shader has one exit, so the three regions the quad covers -
	// the disc, the halo around it, the ring system - decide colour and alpha and
	// fall through to the single assignment at the bottom.
	if (r < 1.0) {
		float z = sqrt(max(1.0 - r * r, 0.0));
		vec3 n = normalize(vec3(q.x, q.y, z));
		float ndl = dot(n, L);
		float day = smoothstep(-0.14, 0.34, ndl);

		// latitude, then dragged around by the flow so the belts are not stripes
		float lat = asin(clamp(q.y, -1.0, 1.0));
		vec2 flow = vec2(time * cloud_drift, 0.0);
		float warp = fbm(q * 2.6 + flow) * turbulence;
		float bands = sin(lat * band_count + warp * 3.4);
		float belt = smoothstep(-0.35, 0.55, bands);

		vec3 surface = mix(band_dark, band_light, belt);
		surface = mix(surface, band_warm, smoothstep(0.55, 0.95, bands) * 0.55);

		// cloud decks: a second, tighter noise field that only shows on the lit side
		float clouds = fbm(q * 6.4 + vec2(time * cloud_drift * 2.3, 1.7));
		clouds = smoothstep(0.42, 0.78, clouds) * cloud_amount;
		surface = mix(surface, band_light * 1.25, clouds * belt);

		// the limb turns away from us, so it goes dark before it goes away
		float edge = pow(z, mix(1.0, 0.28, limb_darkening));
		surface *= mix(1.0, edge, 0.75);
		surface = mix(night_color, surface, day);

		// and the atmosphere catches the star along the day edge
		float rim = pow(1.0 - z, 3.2) * smoothstep(-0.05, 0.75, ndl);
		col = surface + haze_color * rim * 1.35;
		alpha = 1.0;
	} else {
		// ---- the halo the disc cannot hold
		float glow = exp(-(r - 1.0) / max(atmosphere, 0.004));
		// q is a disc coordinate and L is a spatial direction: the comparison is
		// with the projection of the star onto the plane the camera sees
		float side = smoothstep(-0.55, 0.35, dot(normalize(q), L.xy));
		col = haze_color;
		alpha = glow * side * 0.55;

		// ---- rings: an annulus of density noise, with the division and the
		// planet's own shadow across them
		if (show_rings) {
			float rs = length(vec2(q.x, q.y / max(ring_squash, 0.02)));
			if (rs > ring_inner && rs < ring_outer) {
				float t = (rs - ring_inner) / max(ring_outer - ring_inner, 0.001);
				float grain = fbm(vec2(rs * 26.0, 3.7));
				float d = smoothstep(0.28, 0.62, grain);
				d *= smoothstep(0.0, 0.06, t) * (1.0 - smoothstep(0.94, 1.0, t));
				d *= 1.0 - 0.88 * smoothstep(0.44, 0.50, t) * (1.0 - smoothstep(0.50, 0.56, t));
				// the far side of the ring is behind the planet relative to the star
				float lit = smoothstep(-0.42, 0.22, dot(normalize(q), L.xy));
				vec3 rc = ring_color * (0.22 + 0.78 * lit) + haze_color * 0.12 * lit;
				if (d * ring_density > alpha) {
					col = rc;
					alpha = d * ring_density;
				}
			}
		}
	}

	COLOR = vec4(col, alpha);
}
