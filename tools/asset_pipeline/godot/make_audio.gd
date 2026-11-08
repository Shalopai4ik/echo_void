extends SceneTree

## Synthesises every sound of the demo into WAV files: the 19 ship streams
## `ship_audio.gd` asks for, the one-shot effects the game plays by name, and
## five music loops (calm, uncertainty, tension, danger, climax).
##
## Nothing is sampled or downloaded: oscillators, filtered noise, envelopes and
## a small feedback reverb, seeded, so the same run writes the same bytes.
## 22.05 kHz mono 16-bit keeps the whole set small; loops are written with a
## crossfaded tail so they repeat without a click.
##
## Run: godot --headless --path . --script tools/asset_pipeline/godot/make_audio.gd
## Optional: -- only=music  |  only=ship  |  only=sfx

const RATE := 22050
const SHIP_DIR := "res://assets/audio/ship/"
const SFX_DIR := "res://assets/audio/sfx/"
const MUSIC_DIR := "res://assets/audio/music/"

var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("only="):
			only = arg.substr(5)
	for dir in [SHIP_DIR, SFX_DIR, MUSIC_DIR]:
		DirAccess.make_dir_recursive_absolute(dir)
	if only == "" or only == "ship":
		_ship()
	if only == "" or only == "sfx":
		_sfx()
	if only == "" or only == "music":
		_music()
	quit(0)


# ================================================================ primitives ===

func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * RATE))
	return b


func _noise() -> float:
	return _rng.randf() * 2.0 - 1.0


## One-pole low-pass in place.
func _lowpass(b: PackedFloat32Array, cutoff: float) -> void:
	var a := 1.0 - exp(-TAU * cutoff / RATE)
	var y := 0.0
	for i in b.size():
		y += a * (b[i] - y)
		b[i] = y


func _highpass(b: PackedFloat32Array, cutoff: float) -> void:
	var a := 1.0 - exp(-TAU * cutoff / RATE)
	var y := 0.0
	for i in b.size():
		y += a * (b[i] - y)
		b[i] = b[i] - y


## A small Schroeder-style reverb: four combs in parallel, mixed back in.
func _reverb(b: PackedFloat32Array, wet: float, size: float = 1.0) -> void:
	var delays := [1557, 1617, 1491, 1422]
	var out := PackedFloat32Array()
	out.resize(b.size())
	for d in delays:
		var n := int(d * size)
		var line := PackedFloat32Array()
		line.resize(n)
		var idx := 0
		var fb := 0.78
		var damp := 0.0
		for i in b.size():
			var y := line[idx]
			damp = y * 0.6 + damp * 0.4
			line[idx] = b[i] + damp * fb
			idx = (idx + 1) % n
			out[i] += y * 0.25
	for i in b.size():
		b[i] = b[i] * (1.0 - wet * 0.5) + out[i] * wet


func _env(i: int, n: int, attack: float, release: float) -> float:
	var t := float(i) / RATE
	var total := float(n) / RATE
	var a := clampf(t / maxf(attack, 0.0001), 0.0, 1.0)
	var r := clampf((total - t) / maxf(release, 0.0001), 0.0, 1.0)
	return a * r


func _normalize(b: PackedFloat32Array, peak: float = 0.89) -> void:
	var m := 0.0
	for v in b:
		m = maxf(m, absf(v))
	if m <= 0.0:
		return
	var k := peak / m
	for i in b.size():
		b[i] *= k


## Crossfade the last `fade` seconds onto the start and trim them: a seamless loop.
func _make_loop(b: PackedFloat32Array, fade: float) -> PackedFloat32Array:
	var f := int(fade * RATE)
	var n := b.size() - f
	var out := b.slice(0, n)
	for i in f:
		var k := float(i) / float(f)
		out[i] = out[i] * k + b[n + i] * (1.0 - k)
	return out


func _save(b: PackedFloat32Array, path: String) -> void:
	var data := PackedByteArray()
	data.resize(b.size() * 2)
	for i in b.size():
		var s := int(clampf(b[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, s)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	var err := wav.save_to_wav(path)
	print("saved ", path, " ", "%.1f s" % (float(b.size()) / RATE), " err=", err)


# ============================================================ building blocks ===

## A tone with a pitch glide, a waveform mix and an envelope, added into `b`.
func _tone(b: PackedFloat32Array, start: float, length: float, f0: float, f1: float,
		amp: float, shape: String = "sine", attack: float = 0.01, release: float = 0.1) -> void:
	var s := int(start * RATE)
	var n := int(length * RATE)
	var phase := 0.0
	for i in n:
		if s + i >= b.size():
			break
		var k := float(i) / float(maxi(n - 1, 1))
		var f := lerpf(f0, f1, k)
		phase += f / RATE
		var p := fmod(phase, 1.0)
		var v := 0.0
		match shape:
			"sine":
				v = sin(TAU * p)
			"tri":
				v = 4.0 * absf(p - 0.5) - 1.0
			"saw":
				v = 2.0 * p - 1.0
			"square":
				v = 1.0 if p < 0.5 else -1.0
			"soft":
				v = sin(TAU * p) + 0.3 * sin(TAU * p * 2.0) + 0.12 * sin(TAU * p * 3.0)
		b[s + i] += v * amp * _env(i, n, attack, release)


func _noise_burst(b: PackedFloat32Array, start: float, length: float, amp: float,
		attack: float = 0.005, release: float = 0.2) -> void:
	var s := int(start * RATE)
	var n := int(length * RATE)
	for i in n:
		if s + i >= b.size():
			break
		b[s + i] += _noise() * amp * _env(i, n, attack, release)


## Filtered noise bed with a slow wobble - engine textures.
func _engine_loop(seconds: float, cutoff: float, hum: float, hum_amp: float, wobble: float) -> PackedFloat32Array:
	var b := _buf(seconds + 0.5)
	for i in b.size():
		b[i] = _noise()
	_lowpass(b, cutoff)
	_lowpass(b, cutoff * 1.5)
	var phase := 0.0
	for i in b.size():
		var t := float(i) / RATE
		phase += hum / RATE
		b[i] = b[i] * (1.0 + wobble * sin(TAU * 0.5 * t)) + sin(TAU * phase) * hum_amp \
			+ sin(TAU * phase * 2.0) * hum_amp * 0.35
	_normalize(b, 0.8)
	return _make_loop(b, 0.5)


# ================================================================ ship set ===

func _ship() -> void:
	_rng.seed = 1101
	_save(_engine_loop(2.0, 380.0, 55.0, 0.25, 0.08), SHIP_DIR + "engine_main.wav")
	_save(_engine_loop(2.0, 1400.0, 90.0, 0.1, 0.15), SHIP_DIR + "engine_retro.wav")
	_save(_engine_loop(1.5, 2200.0, 0.0, 0.0, 0.2), SHIP_DIR + "engine_strafe.wav")
	_save(_engine_loop(1.5, 1700.0, 0.0, 0.0, 0.35), SHIP_DIR + "engine_rotation.wav")
	_save(_engine_loop(2.0, 700.0, 82.0, 0.35, 0.1), SHIP_DIR + "boost_layer.wav")
	var bed := _buf(3.5)
	_tone(bed, 0.0, 3.5, 110.0, 110.0, 0.2, "sine", 0.3, 0.3)
	_tone(bed, 0.0, 3.5, 165.5, 165.5, 0.1, "sine", 0.3, 0.3)
	for i in bed.size():
		bed[i] += _noise() * 0.02
	_normalize(bed, 0.5)
	_save(_make_loop(bed, 0.5), SHIP_DIR + "stabilizer_bed.wav")
	for spec in [["impact_light", 0.25, 900.0, 0.4], ["impact_medium", 0.5, 600.0, 0.7],
			["impact_heavy", 1.1, 380.0, 1.0]]:
		var b := _buf(float(spec[1]) + 0.6)
		_noise_burst(b, 0.0, float(spec[1]), 1.0, 0.002, float(spec[1]) * 0.9)
		_lowpass(b, float(spec[2]))
		_tone(b, 0.0, float(spec[1]) + 0.4, 70.0, 40.0, float(spec[3]) * 0.6, "sine", 0.002, 0.4)
		_tone(b, 0.02, 0.6, 520.0, 500.0, 0.08 * float(spec[3]), "sine", 0.002, 0.5)
		_reverb(b, 0.25, 0.6)
		_normalize(b)
		_save(b, SHIP_DIR + "%s.wav" % spec[0])
	_save(_beeps([[880.0, 0.06], [1320.0, 0.09]]), SHIP_DIR + "stabilizer_on.wav")
	_save(_beeps([[1320.0, 0.06], [880.0, 0.09]]), SHIP_DIR + "stabilizer_off.wav")
	var whoosh := _buf(0.9)
	_noise_burst(whoosh, 0.0, 0.9, 0.7, 0.3, 0.4)
	_lowpass(whoosh, 1500.0)
	_tone(whoosh, 0.0, 0.9, 80.0, 220.0, 0.5, "saw", 0.2, 0.4)
	_lowpass(whoosh, 1800.0)
	_normalize(whoosh)
	_save(whoosh, SHIP_DIR + "boost_on.wav")
	_save(_beeps([[740.0, 0.07], [0.0, 0.05], [740.0, 0.07]]), SHIP_DIR + "boost_low.wav")
	_save(_beeps([[600.0, 0.1], [400.0, 0.18]], "square", 0.25), SHIP_DIR + "boost_empty.wav")
	_save(_beeps([[880.0, 0.06], [1175.0, 0.06], [1568.0, 0.14]]), SHIP_DIR + "boost_ready.wav")
	_save(_click(1800.0), SHIP_DIR + "control_on.wav")
	_save(_click(900.0), SHIP_DIR + "control_off.wav")
	var em := _buf(0.9)
	for k in 3:
		_tone(em, k * 0.28, 0.2, 980.0, 760.0, 0.4, "square", 0.005, 0.05)
	_lowpass(em, 3000.0)
	_normalize(em, 0.7)
	_save(em, SHIP_DIR + "emergency_on.wav")
	var pw := _buf(1.1)
	_tone(pw, 0.0, 1.0, 120.0, 480.0, 0.5, "saw", 0.05, 0.3)
	_lowpass(pw, 1200.0)
	_tone(pw, 0.8, 0.3, 960.0, 960.0, 0.2, "sine", 0.005, 0.2)
	_normalize(pw, 0.7)
	_save(pw, SHIP_DIR + "power_on.wav")


func _beeps(notes: Array, shape: String = "sine", amp: float = 0.5) -> PackedFloat32Array:
	var total := 0.05
	for n in notes:
		total += float(n[1]) + 0.02
	var b := _buf(total + 0.15)
	var t := 0.0
	for n in notes:
		if float(n[0]) > 0.0:
			_tone(b, t, float(n[1]), float(n[0]), float(n[0]), amp, shape, 0.004, 0.04)
		t += float(n[1]) + 0.02
	if shape == "square":
		_lowpass(b, 2500.0)
	_normalize(b, 0.6)
	return b


func _click(freq: float) -> PackedFloat32Array:
	var b := _buf(0.12)
	_tone(b, 0.0, 0.05, freq, freq * 0.6, 0.6, "sine", 0.001, 0.04)
	_noise_burst(b, 0.0, 0.02, 0.3, 0.001, 0.015)
	_normalize(b, 0.55)
	return b


# ================================================================== effects ===

func _sfx() -> void:
	_rng.seed = 2202
	# scanner ping: a sonar sweep with a tail
	var scan := _buf(2.2)
	_tone(scan, 0.0, 1.2, 1400.0, 700.0, 0.45, "sine", 0.005, 1.0)
	_tone(scan, 0.0, 1.2, 2100.0, 1050.0, 0.12, "sine", 0.005, 1.0)
	_reverb(scan, 0.45, 1.2)
	_normalize(scan, 0.6)
	_save(scan, SFX_DIR + "scan.wav")
	_save(_beeps([[1046.0, 0.07], [1318.0, 0.11]], "sine", 0.4), SFX_DIR + "scan_done.wav")
	var done := _buf(1.6)
	for k in 3:
		_tone(done, k * 0.09, 1.2, [523.25, 659.25, 783.99][k], [523.25, 659.25, 783.99][k], 0.25, "soft", 0.01, 0.9)
	_reverb(done, 0.35)
	_normalize(done, 0.6)
	_save(done, SFX_DIR + "research_done.wav")
	var disc := _buf(1.4)
	_tone(disc, 0.0, 1.0, 1567.0, 1567.0, 0.3, "sine", 0.002, 0.9)
	_tone(disc, 0.12, 0.9, 2093.0, 2093.0, 0.15, "sine", 0.002, 0.8)
	_reverb(disc, 0.5)
	_normalize(disc, 0.5)
	_save(disc, SFX_DIR + "discover.wav")
	_save(_click(2400.0), SFX_DIR + "ui_click.wav")
	_save(_beeps([[880.0, 0.05], [1318.0, 0.08]], "sine", 0.35), SFX_DIR + "ui_confirm.wav")
	var up := _buf(1.2)
	for k in 4:
		var f: float = [392.0, 523.25, 659.25, 1046.5][k]
		_tone(up, k * 0.08, 0.8, f, f, 0.22, "soft", 0.005, 0.6)
	_reverb(up, 0.3)
	_normalize(up, 0.6)
	_save(up, SFX_DIR + "upgrade.wav")
	_save(_beeps([[180.0, 0.18]], "square", 0.3), SFX_DIR + "refuse.wav")
	_save(_beeps([[660.0, 0.14], [520.0, 0.18]], "tri", 0.45), SFX_DIR + "warning.wav")
	var alarm := _buf(1.2)
	for k in 4:
		_tone(alarm, k * 0.28, 0.2, 1200.0, 900.0, 0.35, "square", 0.004, 0.05)
	_lowpass(alarm, 2600.0)
	_normalize(alarm, 0.55)
	_save(alarm, SFX_DIR + "alarm.wav")
	var hit := _buf(1.4)
	_noise_burst(hit, 0.0, 0.5, 1.0, 0.002, 0.45)
	_lowpass(hit, 500.0)
	_tone(hit, 0.0, 1.0, 62.0, 38.0, 0.7, "sine", 0.002, 0.8)
	_tone(hit, 0.1, 1.2, 310.0, 290.0, 0.06, "saw", 0.2, 0.9)
	_reverb(hit, 0.3, 0.7)
	_normalize(hit)
	_save(hit, SFX_DIR + "hull_hit.wav")
	var sq := _buf(0.35)
	_noise_burst(sq, 0.0, 0.08, 0.6, 0.001, 0.07)
	_highpass(sq, 1200.0)
	_tone(sq, 0.08, 0.06, 1900.0, 1900.0, 0.3, "sine", 0.002, 0.03)
	_normalize(sq, 0.45)
	_save(sq, SFX_DIR + "comms_in.wav")
	var st := _buf(2.0)
	var amp := 0.0
	for i in st.size():
		if i % 400 == 0:
			amp = _rng.randf() * _rng.randf()
		st[i] = _noise() * amp
	_highpass(st, 400.0)
	_lowpass(st, 4500.0)
	for i in st.size():
		st[i] *= _env(i, st.size(), 0.05, 0.4)
	_normalize(st, 0.5)
	_save(st, SFX_DIR + "radio_static.wav")
	var ph := _buf(2.6)
	_tone(ph, 0.0, 0.5, 1174.0, 1180.0, 0.3, "sine", 0.002, 0.45)
	_tone(ph, 0.0, 0.5, 1109.0, 1100.0, 0.2, "sine", 0.002, 0.45)
	_tone(ph, 0.8, 0.5, 1174.0, 1150.0, 0.1, "sine", 0.002, 0.45)
	_reverb(ph, 0.6, 1.4)
	_normalize(ph, 0.5)
	_save(ph, SFX_DIR + "phantom_ping.wav")
	_save(_creature_call(), SFX_DIR + "creature_call.wav")
	_save(_rumble(4.5, 0.6, 38.0), SFX_DIR + "creature_near.wav")
	_save(_roar(), SFX_DIR + "creature_roar.wav")
	_save(_rumble(2.5, 0.9, 30.0), SFX_DIR + "tremor.wav")
	var fl := _buf(1.0)
	for i in fl.size():
		var crackle := 1.0 if _rng.randf() < 0.02 else 0.15
		fl[i] = _noise() * crackle
	_highpass(fl, 600.0)
	_tone(fl, 0.0, 0.7, 50.0, 50.0, 0.3, "square", 0.01, 0.3)
	_lowpass(fl, 5000.0)
	for i in fl.size():
		fl[i] *= _env(i, fl.size(), 0.01, 0.4)
	_normalize(fl, 0.45)
	_save(fl, SFX_DIR + "power_flicker.wav")
	var flare := _buf(1.8)
	_noise_burst(flare, 0.0, 1.8, 0.8, 0.02, 1.2)
	_highpass(flare, 900.0)
	_tone(flare, 0.0, 0.25, 300.0, 900.0, 0.3, "saw", 0.005, 0.1)
	_lowpass(flare, 6000.0)
	_normalize(flare, 0.55)
	_save(flare, SFX_DIR + "flare.wav")
	var dl := _buf(1.0)
	_tone(dl, 0.0, 0.25, 140.0, 60.0, 0.7, "sine", 0.002, 0.2)
	_noise_burst(dl, 0.0, 0.15, 0.5, 0.002, 0.12)
	_lowpass(dl, 1200.0)
	_tone(dl, 0.2, 0.5, 900.0, 1800.0, 0.15, "sine", 0.01, 0.3)
	_normalize(dl, 0.6)
	_save(dl, SFX_DIR + "decoy_launch.wav")
	_save(_chitter(1.2, 0.0), SFX_DIR + "brood_emerge.wav")
	var za := _buf(1.0)
	_tone(za, 0.0, 0.45, 200.0, 1400.0, 0.4, "saw", 0.05, 0.05)
	_noise_burst(za, 0.45, 0.4, 0.8, 0.002, 0.35)
	_lowpass(za, 3500.0)
	_tone(za, 0.45, 0.4, 90.0, 60.0, 0.5, "sine", 0.002, 0.35)
	_normalize(za, 0.6)
	_save(za, SFX_DIR + "brood_attack.wav")
	var die := _chitter(0.6, 0.3)
	_save(die, SFX_DIR + "brood_die.wav")


func _creature_call() -> PackedFloat32Array:
	var b := _buf(7.0)
	var phase := 0.0
	var phase2 := 0.0
	for i in b.size():
		var t := float(i) / RATE
		var f := 62.0 + 30.0 * sin(t * 0.7) + 18.0 * sin(t * 2.3)
		phase += f / RATE
		phase2 += f * 1.502 / RATE
		var e := sin(clampf(t / 6.5, 0.0, 1.0) * PI)
		b[i] = (sin(TAU * phase) * 0.7 + sin(TAU * phase2) * 0.3 + sin(TAU * phase * 3.0) * 0.12) * e
	_lowpass(b, 700.0)
	_reverb(b, 0.75, 1.8)
	_normalize(b, 0.7)
	return b


func _rumble(seconds: float, amount: float, freq: float) -> PackedFloat32Array:
	var b := _buf(seconds)
	for i in b.size():
		b[i] = _noise()
	_lowpass(b, 120.0)
	_lowpass(b, 160.0)
	var phase := 0.0
	for i in b.size():
		var t := float(i) / RATE
		phase += (freq + 6.0 * sin(t * 3.0)) / RATE
		b[i] = (b[i] * 3.0 + sin(TAU * phase) * 0.6) * _env(i, b.size(), seconds * 0.35, seconds * 0.5) * amount
	_normalize(b, 0.85)
	return b


func _roar() -> PackedFloat32Array:
	var b := _rumble(6.5, 1.0, 34.0)
	var phase := 0.0
	for i in b.size():
		var t := float(i) / RATE
		phase += (48.0 + 20.0 * sin(t * 0.9)) / RATE
		var growl := (2.0 * fmod(phase, 1.0) - 1.0) * (0.5 + 0.5 * sin(t * 31.0))
		b[i] += growl * 0.25 * sin(clampf(t / 6.5, 0.0, 1.0) * PI)
	_lowpass(b, 900.0)
	_reverb(b, 0.6, 1.6)
	_normalize(b, 0.9)
	return b


func _chitter(seconds: float, low: float) -> PackedFloat32Array:
	var b := _buf(seconds + 0.4)
	var t := 0.0
	while t < seconds:
		var f := _rng.randf_range(1800.0, 3400.0) * (1.0 - low)
		_tone(b, t, 0.025, f, f * 0.7, 0.3, "saw", 0.001, 0.02)
		t += _rng.randf_range(0.02, 0.07)
	_noise_burst(b, 0.0, seconds, 0.08, 0.1, 0.3)
	_lowpass(b, 5000.0)
	_reverb(b, 0.3, 0.8)
	_normalize(b, 0.5)
	return b


# ==================================================================== music ===

## Five 32-second loops. Same key (A minor) and tempo grid, so the director can
## cross-fade between them at any moment.
func _music() -> void:
	_rng.seed = 3303
	var len := 34.0
	_save(_make_loop(_calm(len), 2.0), MUSIC_DIR + "calm.wav")
	_save(_make_loop(_uncertain(len), 2.0), MUSIC_DIR + "uncertain.wav")
	_save(_make_loop(_tension(len), 2.0), MUSIC_DIR + "tension.wav")
	_save(_make_loop(_danger(len), 2.0), MUSIC_DIR + "danger.wav")
	_save(_make_loop(_climax(len), 2.0), MUSIC_DIR + "climax.wav")


## A soft pad chord held for `length`, slightly detuned voices.
func _pad(b: PackedFloat32Array, start: float, length: float, freqs: Array, amp: float,
		attack: float = 2.0, release: float = 2.0) -> void:
	for f in freqs:
		_tone(b, start, length, float(f), float(f), amp, "sine", attack, release)
		_tone(b, start, length, float(f) * 1.003, float(f) * 1.003, amp * 0.6, "tri", attack, release)


func _calm(len: float) -> PackedFloat32Array:
	var b := _buf(len)
	var chords := [[110.0, 164.8, 220.0, 261.6], [87.3, 130.8, 174.6, 220.0],
		[130.8, 164.8, 196.0, 261.6], [98.0, 146.8, 196.0, 246.9]]
	for k in 4:
		_pad(b, k * 8.0, 10.0, chords[k], 0.07, 3.0, 3.0)
	for k in 8:
		var f: float = [659.3, 523.3, 587.3, 493.9, 440.0, 523.3, 392.0, 440.0][k]
		_tone(b, 1.0 + k * 4.0, 3.2, f, f, 0.035, "sine", 0.02, 2.8)
	_lowpass(b, 1600.0)
	_reverb(b, 0.55, 1.6)
	_normalize(b, 0.55)
	return b


func _uncertain(len: float) -> PackedFloat32Array:
	var b := _buf(len)
	_pad(b, 0.0, len, [55.0, 82.4], 0.08, 4.0, 4.0)
	_pad(b, 0.0, 17.0, [220.0, 233.1], 0.035, 5.0, 5.0)
	_pad(b, 17.0, 17.0, [207.7, 220.0], 0.035, 5.0, 5.0)
	for k in 6:
		var at := 2.5 + k * 5.3
		var f: float = [1318.5, 1244.5, 1396.9, 1174.7, 1318.5, 1108.7][k]
		_tone(b, at, 2.5, f, f * 0.995, 0.03, "sine", 0.005, 2.3)
	_lowpass(b, 2200.0)
	_reverb(b, 0.65, 1.8)
	_normalize(b, 0.55)
	return b


func _heartbeat(b: PackedFloat32Array, bpm: float, amp: float, len: float) -> void:
	var step := 60.0 / bpm
	var t := 0.0
	while t < len:
		_tone(b, t, 0.25, 60.0, 42.0, amp, "sine", 0.004, 0.2)
		_tone(b, t + 0.22, 0.22, 55.0, 40.0, amp * 0.7, "sine", 0.004, 0.18)
		t += step


func _tension(len: float) -> PackedFloat32Array:
	var b := _buf(len)
	_pad(b, 0.0, len, [55.0, 58.3], 0.09, 3.0, 3.0)
	_heartbeat(b, 52.0, 0.4, len)
	var phase := 0.0
	for i in b.size():
		var t := float(i) / RATE
		phase += 220.0 / RATE
		var trem := 0.5 + 0.5 * sin(TAU * 6.0 * t)
		b[i] += (2.0 * fmod(phase, 1.0) - 1.0) * 0.025 * trem * (0.5 + 0.5 * sin(TAU * t / 16.0))
	_lowpass(b, 1400.0)
	_reverb(b, 0.45, 1.4)
	_normalize(b, 0.6)
	return b


func _danger(len: float) -> PackedFloat32Array:
	var b := _buf(len)
	_pad(b, 0.0, len, [55.0, 58.3, 77.8], 0.08, 1.5, 1.5)
	_heartbeat(b, 96.0, 0.45, len)
	var t := 0.0
	while t < len:
		_noise_burst(b, t, 0.18, 0.12, 0.002, 0.16)
		t += 60.0 / 96.0 * 2.0
	for k in 8:
		var f: float = [440.0, 466.2, 415.3, 466.2][k % 4]
		_tone(b, k * 4.0, 3.5, f, f * 0.98, 0.04, "saw", 0.4, 1.5)
	_lowpass(b, 2000.0)
	_reverb(b, 0.35, 1.2)
	_normalize(b, 0.68)
	return b


func _climax(len: float) -> PackedFloat32Array:
	var b := _buf(len)
	var roots := [55.0, 43.65, 49.0, 41.2]
	for k in 4:
		var r: float = roots[k]
		for mult in [1.0, 1.5, 2.0, 2.4]:
			_tone(b, k * 8.0, 9.0, r * mult, r * mult, 0.05, "saw", 0.6, 1.2)
	_heartbeat(b, 120.0, 0.5, len)
	# a choir-like vowel: stacked sines with a slow swell
	for k in 4:
		for f in [440.0, 523.3, 659.3]:
			_tone(b, k * 8.0 + 1.0, 7.0, f * [1.0, 0.8, 0.89, 0.75][k], f * [1.0, 0.8, 0.89, 0.75][k], 0.025, "soft", 2.0, 2.0)
	var t := 0.0
	while t < len:
		_noise_burst(b, t, 0.3, 0.2, 0.002, 0.28)
		t += 2.0
	_lowpass(b, 2400.0)
	_reverb(b, 0.4, 1.3)
	_normalize(b, 0.72)
	return b
