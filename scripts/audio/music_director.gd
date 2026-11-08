extends Node
class_name MusicDirector

## Five music states, always playing in lock-step and cross-faded by what is
## happening - so a change of mood never restarts a track:
##
##   calm       - quiet exploration (soft, muted pads);
##   uncertain  - something is listening (the creature watches, deeper chapters);
##   tension    - it is searching (attention high, the creature investigating);
##   danger     - it is close (approaching, the brood is out);
##   climax     - the manifestation and the finale at the Source.
##
## The state is read from `Leviathan`, `ThreatAttention`, the brood group and
## the mission's chapter; nothing else drives it. While a panel is open the
## music is ducked, not stopped.

const GROUP := "music"
const TRACKS := ["calm", "uncertain", "tension", "danger", "climax"]
const DIR := "res://assets/audio/music/"
const FADE_PER_SEC := 0.28
const DUCK := 0.45

enum Mood { CALM, UNCERTAIN, TENSION, DANGER, CLIMAX }

var _players: Array[AudioStreamPlayer] = []
var _levels: Array[float] = [1.0, 0.0, 0.0, 0.0, 0.0]
var _mood: int = Mood.CALM
var _forced: int = -1


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	for name in TRACKS:
		var p := AudioStreamPlayer.new()
		p.bus = &"Music" if AudioMixer.has_bus(&"Music") else &"Master"
		var stream := load(DIR + name + ".wav") as AudioStream
		if stream is AudioStreamWAV:
			var wav := stream as AudioStreamWAV
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_begin = 0
			wav.loop_end = int(wav.get_length() * wav.mix_rate)
		p.stream = stream
		p.volume_db = -80.0
		add_child(p)
		_players.append(p)
	for p in _players:
		if p.stream != null:
			p.play()


func mood() -> int:
	return _mood


func mood_name() -> String:
	return TRACKS[_mood]


## Pin a mood (the end screen); -1 releases it.
func force_mood(value: int) -> void:
	_forced = value


func _process(delta: float) -> void:
	_mood = _forced if _forced >= 0 else _pick()
	var duck := DUCK if not get_tree().get_nodes_in_group("ui_modal").is_empty() and _forced < 0 else 1.0
	for i in _players.size():
		var want := 1.0 if i == _mood else 0.0
		_levels[i] = move_toward(_levels[i], want, delta * FADE_PER_SEC)
		var lin := _levels[i] * duck
		_players[i].volume_db = linear_to_db(maxf(lin, 0.0001))


func _pick() -> int:
	var tree := get_tree()
	var lev := tree.get_first_node_in_group(Leviathan.GROUP) as Leviathan
	var att := tree.get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
	var mission := tree.get_first_node_in_group("mission")
	var chapter := int(mission.call("chapter")) if mission != null and mission.has_method("chapter") else 0
	if lev != null and lev.state() == Leviathan.State.MANIFEST:
		return Mood.CLIMAX
	if chapter >= 4 and mission != null:
		var desk := GameNodes.device(tree, "Research")
		var desk_busy := desk != null and str(desk.call("current_subject")) == "poi:source"
		if desk_busy or (lev != null and lev.is_near()):
			return Mood.CLIMAX
	if not tree.get_nodes_in_group("brood").is_empty() or (lev != null and lev.state() == Leviathan.State.APPROACHING):
		return Mood.DANGER
	var a := att.attention() if att != null else 0.0
	if (lev != null and lev.state() == Leviathan.State.INVESTIGATING) or a >= 45.0:
		return Mood.TENSION
	if (lev != null and lev.state() == Leviathan.State.OBSERVING) or a >= 20.0 or chapter >= 3:
		return Mood.UNCERTAIN
	return Mood.CALM
