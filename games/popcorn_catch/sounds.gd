extends Node
## Short synthesized arcade cues with a shared, bounded voice pool.

const RATE := 22050
const VOICES := 6
const PRIORITY := {"catch": 0, "bank": 1, "wobble": 2, "big_bank": 3, "spill": 4}
# Onset, duration, frequency, level, pitch sweep and noise for each layer.
const CUES := {
	"catch": [[0.0, 0.09, 860.0, 0.46, -390.0, 0.53], [0.017, 0.094, 1290.0, 0.30, -130.0, 0.12]],
	"wobble": [[0.0, 0.16, 570.0, 0.58, -142.0, 0.17], [0.087, 0.18, 446.0, 0.52, -109.0, 0.19]],
	"spill": [[0.0, 0.16, 430.0, 0.57, -220.0, 0.64], [0.055, 0.17, 318.0, 0.45, -145.0, 0.57],
		[0.104, 0.20, 196.0, 0.40, -75.0, 0.29]],
	"bank": [[0.0, 0.11, 523.25, 0.62, -187.0, 0.22], [0.060, 0.22, 1046.50, 0.50, 0.0, 0.02]],
	"big_bank": [[0.0, 0.18, 523.25, 0.57, 0.0, 0.08], [0.048, 0.25, 783.99, 0.55, 0.0, 0.03],
		[0.117, 0.31, 1046.50, 0.53, 0.0, 0.0]],
	"burst": [[0.0, 0.13, 416.0, 0.46, -88.0, 0.42], [0.066, 0.18, 680.0, 0.49, 74.0, 0.19],
		[0.134, 0.20, 932.0, 0.40, 53.0, 0.13]],
	"ten_seconds": [[0.0, 0.14, 740.0, 0.42, 0.0, 0.0], [0.15, 0.17, 740.0, 0.46, 0.0, 0.0]],
	"time_up": [[0.0, 0.26, 783.99, 0.54, 0.0, 0.0], [0.13, 0.28, 587.33, 0.48, 0.0, 0.0],
		[0.27, 0.34, 392.0, 0.44, 0.0, 0.0]],
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
