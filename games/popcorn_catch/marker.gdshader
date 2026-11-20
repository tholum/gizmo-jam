shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform vec4 tint : source_color = vec4(1.0, 0.83, 0.51, 1.0);
uniform float progress = 0.0;
uniform bool center_drop = false;
uniform bool settled = false;
uniform bool caught = false;
uniform float pulse = 0.0;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float theta = atan(p.y, p.x);
	float a = fract((theta + 1.57079633) / 6.28318531 + 1.0);
	float site = mix(0.36, 0.69, progress);
	float shadow = (1.0 - smoothstep(site - 0.05, site + 0.02, r)) * 0.92;
	float fixed_edge = 1.0 - smoothstep(0.029, 0.044, abs(r - 0.68));
	float rim = 1.0 - smoothstep(0.037, 0.059, abs(r - 0.84));
	float tick = smoothstep(0.84, 0.97, cos(theta * (center_drop ? 8.0 : 4.0)));
	float ready = step(a, progress);
	float star = (1.0 - smoothstep(0.028, 0.047, min(abs(p.x), abs(p.y)))) * (1.0 - smoothstep(0.225, 0.255, r));
	float mark = max(fixed_edge * 0.66, max(star * 0.81, rim * max(ready, tick * 0.64)));
	vec3 ink = vec3(0.025, 0.055, 0.058);
	vec3 bright = tint.rgb;
	float opacity = max(shadow, mark);
	if (settled) {
		float echo = 1.0 - smoothstep(0.03, 0.065, abs(r - mix(0.48, 0.92, pulse)));
		float x = (1.0 - smoothstep(0.034, 0.065, abs(abs(p.x) - abs(p.y)))) * (1.0 - smoothstep(0.22, 0.28, r));
		opacity = max(echo, x * (caught ? 0.0 : 0.8)) * (1.0 - pulse);
		mark = 1.0;
	}
	ALBEDO = mix(ink, bright, mark);
	ALPHA = opacity;
}
