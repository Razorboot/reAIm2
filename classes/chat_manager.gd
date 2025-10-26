extends Control

# --- External refs ---
@export var chat: NarratorBackend
@export var chatLabel: RichTextLabel
@export var editLabel: TextEdit
@export var continueButton: Button
@export var msPea: Node3D
@export var voiceBitPlayer: AudioStreamPlayer
@export var voiceBitSounds: Array            # Array[AudioStream]
@export var peaSpring: Node3D

# --- Typewriter tuning ---
@export var chars_per_sec: float = 30.0
@export var start_text := ""                 # first message you send to the AI (introText)

# Pauses (multipliers on base time = 1/chars_per_sec)
@export var pause_mult_period: float = 6.0   # . ! ?
@export var pause_mult_comma: float = 3.0    # , ;
@export var pause_mult_dash: float = 3.0     # - — –
@export var pause_mult_newline: float = 6.0  # \n

# Voice blip pitch jitter
@export var pitch_jitter: float = 0.07

# Visual wobble
@export var time_passed_multiplier: float = 1.0
@export var scale_multiplier: float = 0.1

# --- Internal typewriter state ---
var _full_text := ""
var _visible_chars := 0
var _accum := 0.0
var _time_passed := 0.0

# --- Game flow state ---
enum State { Intro, ThemeInput, AIWait, AIDisplay }
var _state: int = State.Intro
var _just_revealed := false

# Theme & chat loop
const THEME_CHAR_MAX := 150
var _has_theme := false
var _chosen_theme := ""

# Ms. Pea defaults
var msPeaDefaultScale: Vector3
var msPeaDefaultRotation: Vector3

func _ready() -> void:
	if chat == null:
		push_error("Chat node not assigned"); return
	if chatLabel == null or editLabel == null or continueButton == null:
		push_error("UI references not assigned"); return

	randomize()

	msPeaDefaultScale = msPea.scale
	msPeaDefaultRotation = msPea.rotation

	# Connect backend
	chat.reply_ready.connect(_on_reply_ready)
	chat.error.connect(_on_chat_error)

	# Button
	continueButton.pressed.connect(_on_continue_pressed)
	continueButton.disabled = false

	# UI setup
	editLabel.visible = false
	editLabel.text = ""
	_set_continue_text("Skip")

	# Start fresh conversation and kick off the intro
	chat.reset_conversation()
	_state = State.AIWait
	_start_typewriter("Ms. Pea is thinking...")
	continueButton.disabled = true
	chat.send_message(start_text)

func _process(delta: float) -> void:
	_time_passed += delta * time_passed_multiplier

	# typewriter when we’re rendering NPC text
	if _state == State.Intro or _state == State.AIDisplay:
		_typewriter_tick(delta)

	# squash & stretch
	if _is_typing():
		var pWave: float = sin(_time_passed) * scale_multiplier
		var pWaveHalf: float = sin(_time_passed * 0.5) * scale_multiplier
		msPea.scale.y = lerp(msPea.scale.y, msPeaDefaultScale.y + pWave, delta)
		msPea.rotation.z = lerp(msPea.rotation.z, msPeaDefaultRotation.z + pWaveHalf, delta)
	else:
		msPea.scale.y = lerp(msPea.scale.y, msPeaDefaultScale.y, delta)
		msPea.rotation.z = lerp(msPea.rotation.z, msPeaDefaultRotation.z, delta)

# ------------------------------------------------
# Button behavior (Skip → reveal, click again → advance)
# ------------------------------------------------
func _on_continue_pressed() -> void:
	# 1) If text is still typing → reveal all
	if _is_typing():
		_reveal_all()
		_just_revealed = true
		return

	# 2) If we just revealed on the last click → this click advances
	if _just_revealed:
		_just_revealed = false
		_advance_after_reveal()
		return

	# 3) Otherwise advance based on state
	match _state:
		State.Intro, State.AIDisplay:
			_goto_theme_input()
		State.ThemeInput:
			_submit_input()   # handles theme vs questions
		State.AIWait:
			# do nothing (still thinking)
			pass

func _advance_after_reveal() -> void:
	match _state:
		State.Intro, State.AIDisplay:
			_goto_theme_input()
		State.ThemeInput:
			_submit_input()
		State.AIWait:
			pass

# ------------------------------------------------
# Chat callbacks
# ------------------------------------------------
func _on_reply_ready(t: String) -> void:
	continueButton.disabled = false
	_start_typewriter(t)
	# Intro (first reply) vs normal back-and-forth
	if _state == State.AIWait and not _has_theme:
		_state = State.Intro
	else:
		_state = State.AIDisplay
	_set_continue_text("Skip")

func _on_chat_error(msg: String) -> void:
	continueButton.disabled = false
	_start_typewriter("[ERROR] " + msg)
	_state = State.AIDisplay
	_set_continue_text("Skip")

# ------------------------------------------------
# State transitions
# ------------------------------------------------
func _goto_theme_input() -> void:
	_state = State.ThemeInput
	chatLabel.visible = false
	editLabel.visible = true
	editLabel.grab_focus()
	_set_continue_text("Ask" if  _has_theme else "Send")

# Handles BOTH the initial theme AND subsequent questions.
func _submit_input() -> void:
	var text := editLabel.text.strip_edges()
	if text.length() == 0:
		return

	# Initial theme
	if not _has_theme:
		if text.length() > THEME_CHAR_MAX:
			text = text.substr(0, THEME_CHAR_MAX)
		_chosen_theme = text
		_has_theme = true

		# Pin the theme into backend memory and trigger Ms. Pea's themed intro
		chat.set_theme(_chosen_theme)
		_send_ai_and_wait("The theme is: " + _chosen_theme)
		return

	# Subsequent questions → normal chat turns (memory already contains theme)
	_send_ai_and_wait(text)

func _send_ai_and_wait(outgoing: String) -> void:
	# Clear input, show thinking, go to AIWait
	editLabel.clear()
	editLabel.visible = false
	chatLabel.visible = true
	_start_typewriter("Ms. Pea is thinking...")
	_set_continue_text("Skip")
	_state = State.AIWait
	continueButton.disabled = true
	chat.send_message(outgoing)

# ------------------------------------------------
# Typewriter
# ------------------------------------------------
func _start_typewriter(t: String) -> void:
	_full_text = t
	_visible_chars = 0
	_accum = 0.0
	_just_revealed = false
	chatLabel.text = ""

func _is_typing() -> bool:
	return _visible_chars < _full_text.length()

func _reveal_all() -> void:
	_visible_chars = _full_text.length()
	_accum = 0.0
	chatLabel.text = _full_text

func _typewriter_tick(delta: float) -> void:
	if not _is_typing():
		return

	_accum += delta
	while _visible_chars < _full_text.length():
		var ch: String = _full_text[_visible_chars]
		var need := _delay_for_char(ch)
		if _accum < need:
			break
		_accum -= need
		_visible_chars += 1
		chatLabel.text = _full_text.substr(0, _visible_chars)
		_play_voice_bit_for_char(ch)

func _delay_for_char(ch: String) -> float:
	var base: float = 1.0 / max(chars_per_sec, 1.0)
	match ch:
		".", "!", "?":
			return base * pause_mult_period
		",", ";":
			return base * pause_mult_comma
		"-", "—", "–":
			return base * pause_mult_dash
		"\n":
			return base * pause_mult_newline
		_:
			return base

func _play_voice_bit_for_char(ch: String) -> void:
	if ch == " " or ch == "\n" or ch == "\r" or ch == "\t":
		return
	if voiceBitPlayer == null or voiceBitSounds.is_empty():
		return
	var idx := randi() % voiceBitSounds.size()
	var stream := voiceBitSounds[idx] as AudioStream
	if stream == null:
		return
	voiceBitPlayer.stream = stream
	voiceBitPlayer.pitch_scale = clamp(1.0 + randf_range(-pitch_jitter, pitch_jitter), 0.5, 2.0)
	voiceBitPlayer.play()

func _set_continue_text(t: String) -> void:
	if continueButton:
		continueButton.text = t
