extends Node
## Short synthesized game cues. Built on first audible use and cached across rounds.

const RATE := 22050
const VOICES := 4
const CUES := {
	"hook": [[0.00, 0.13, 445.0, 0.62, -160.0, 0.34], [0.06, 0.18, 740.0, 0.52, -50.0, 0.09]],
	"cut": [[0.00, 0.18, 680.0, 0.86, -580.0, 0.65], [0.04, 0.23, 340.0, 0.53, -295.0, 0.18]],
	"lost": [[0.00, 0.25, 360.0, 0.58, -220.0, 0.25], [0.12, 0.24, 264.0, 0.41, -80.0, 0.0]],
	"release": [[0.00, 0.16, 500.0, 0.47, -165.0, 0.15]],
	"bank": [[0.00, 0.21, 587.33, 0.54, 0.0, 0.0], [0.09, 0.30, 880.0, 0.50, 0.0, 0.0]],
	"bank_heavy": [[0.00, 0.21, 587.33, 0.54, 0.0, 0.0], [0.08, 0.26, 880.0, 0.46, 0.0, 0.0],
		[0.17, 0.34, 1174.66, 0.39, 0.0, 0.0]],
}

static var _clips: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _oldest := 0

func cue(id: String, volume: float, pitch: float = 1.0) -> void:
	if not _clips.has(id):
		_clips[id] = _synthesize(CUES[id])
	if _pool.is_empty():
		for i in VOICES:
			var voice := AudioStreamPlayer.new()
			add_child(voice)
			_pool.append(voice)
	var index := _oldest
	for i in VOICES:
		var try_index := (_oldest + i) % VOICES
		if not _pool[try_index].playing:
			index = try_index
			break
	var voice := _pool[index]
	_oldest = (index + 1) % VOICES
	voice.stream = _clips[id]
	voice.volume_db = volume
	voice.pitch_scale = pitch
	voice.play()

func stop() -> void:
	for voice in _pool:
		voice.stop()

static func _synthesize(notes: Array) -> AudioStreamWAV:
	var length := 0
	for part in notes:
		length = maxi(length, ceili((part[0] + part[1]) * RATE))
	var mix := PackedFloat32Array()
	mix.resize(length)
	var rng := RandomNumberGenerator.new()
	rng.seed = 808
	for part in notes:
		var start := roundi(part[0] * RATE)
		var count := roundi(part[1] * RATE)
		var amplitude: float = part[3]
		var noise: float = part[5]
		for i in mini(count, length - start):
			var t := float(i) / RATE
			var age := float(i) / count
			var envelope := minf(1.0, t / 0.005) * exp(-age * 4.0) * (1.0 - age)
			var p: float = TAU * t * (part[2] + 0.5 * age * part[4])
			var tone := sin(p) * 0.71 + sin(p * 2.008) * 0.20 + sin(p * 3.03) * 0.09
			mix[start + i] += lerpf(tone, rng.randf_range(-1.0, 1.0), noise) * amplitude * envelope
	var pcm := PackedByteArray()
	pcm.resize(length * 2)
	for i in length:
		pcm.encode_s16(i * 2, roundi(clampf(mix[i], -1.0, 1.0) * 32767.0))
	var clip := AudioStreamWAV.new()
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = RATE
	clip.data = pcm
	return clip
