extends Node
## Short synthesized arcade cues with a shared, bounded voice pool.

const RATE := 22050
const VOICES := 6
# Onset, duration, frequency, level, pitch sweep and noise for each layer.
const CUES := {
	"swap": [[0.0, 0.12, 330.0, 0.42, 220.0, 0.2], [0.08, 0.18, 784.0, 0.48, 150.0, 0.04]],
	"fit": [[0.0, 0.09, 187.0, 0.35, 35.0, 0.57], [0.06, 0.15, 587.33, 0.4, 0.0, 0.03]],
	"close": [[0.0, 0.15, 277.18, 0.49, -52.0, 0.22], [0.07, 0.11, 207.0, 0.32, -18.0, 0.3]],
	"bell": [[0.0, 0.6, 659.25, 0.55, 0.0, 0.04], [0.03, 0.4, 392.0, 0.3, 0.0, 0.04]],
	"finish": [[0.0, 0.24, 523.25, 0.42, 0.0, 0.07], [0.10, 0.20, 659.25, 0.38, 0.0, 0.07],
		[0.20, 0.42, 1046.50, 0.40, 0.0, 0.06]],
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
