extends Node
## Short synthesized arcade cues with a shared, bounded voice pool.

const RATE := 22050
const VOICES := 6
# Onset, duration, frequency, level, pitch sweep and noise for each layer.
const CUES := {
	"drawer_open": [[0.0, 0.11, 169.0, 0.28, 71.0, 0.45]],
	"treat": [[0.0, 0.06, 270.0, 0.30, -83.0, 0.46], [0.035, 0.15, 587.33, 0.55, 48.0, 0.10]],
	"double_treat": [[0.0, 0.07, 323.0, 0.32, -87.0, 0.36], [0.022, 0.14, 659.25, 0.54, 0.0, 0.05],
		[0.085, 0.22, 987.77, 0.51, 0.0, 0.04]],
	"restock": [[0.0, 0.13, 293.66, 0.26, -25.0, 0.27], [0.082, 0.16, 587.33, 0.42, 0.0, 0.10],
		[0.163, 0.22, 880.0, 0.44, 0.0, 0.06]],
	"finish": [[0.0, 0.24, 880.0, 0.42, 0.0, 0.07], [0.10, 0.20, 739.99, 0.38, 0.0, 0.07],
		[0.20, 0.28, 587.33, 0.40, 0.0, 0.06]],
}

static var _clips: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _oldest := 0

func cue(id: String, volume: float) -> void:
	if not _clips.has(id):
		_clips[id] = _synthesize(CUES[id])
	if _pool.is_empty():
		for i in VOICES:
			var player := AudioStreamPlayer.new()
			add_child(player)
			_pool.append(player)
	var index := _oldest
	for i in VOICES:
		var candidate := (_oldest + i) % VOICES
		if not _pool[candidate].playing:
			index = candidate
			break
	_oldest = (index + 1) % VOICES
	var voice := _pool[index]
	voice.stream = _clips[id]
	voice.volume_db = volume
	voice.play()

func stop() -> void:
	for voice in _pool:
		voice.stop()

static func _synthesize(parts: Array) -> AudioStreamWAV:
	var length := 0
	for part in parts:
		length = maxi(length, ceili((part[0] + part[1]) * RATE))
	var mix := PackedFloat32Array()
	mix.resize(length)
	var rng := RandomNumberGenerator.new()
	rng.seed = 727
	for part in parts:
		var start := roundi(part[0] * RATE)
		var count := mini(length - start, roundi(part[1] * RATE))
		var amplitude: float = part[3]
		var noise: float = part[5]
		for i in count:
			var seconds := float(i) / RATE
			var age := float(i) / count
			var envelope := minf(1.0, seconds / 0.0035) * exp(-age * 4.8) * (1.0 - age)
			var phase: float = TAU * seconds * (part[2] + 0.5 * age * part[4])
			var bell := sin(phase) * 0.67 + sin(phase * 2.018) * 0.19 + sin(phase * 3.93) * 0.14
			mix[start + i] += lerpf(bell, rng.randf_range(-1.0, 1.0), noise) * amplitude * envelope
	var pcm := PackedByteArray()
	pcm.resize(length * 2)
	for i in length:
		pcm.encode_s16(i * 2, roundi(clampf(mix[i], -1.0, 1.0) * 32767.0))
	var clip := AudioStreamWAV.new()
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = RATE
	clip.data = pcm
	return clip
