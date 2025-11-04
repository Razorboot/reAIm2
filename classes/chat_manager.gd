extends Control

# --- External refs ---
@export var chat: NarratorBackend
@export var rodin: RodinGen2Loader

@export var chatLabel: RichTextLabel
@export var editLabel: TextEdit
@export var continueButton: Button
@export var msPea: Node3D
@export var voiceBitPlayer: AudioStreamPlayer
@export var winSoundPlayer: AudioStreamPlayer
@export var failSoundPlayer: AudioStreamPlayer
@export var voiceBitSounds: Array            # Array[AudioStream]
@export var peaSpring: Node3D
@export var uiBox: TextureRect

@export var objectDrop: Node3D

@export var Cam: Camera3D
@export var CamStart: Node3D
@export var CamEnd: Node3D
@export var finalCamPoint: Node3D

var playerWon: bool = false
var endObject: RigidBody3D                   # assign in editor

# --- Cinematic tuning ---
@export var cam_move_time: float = 2.5
@export var ui_fade_time: float = 0.6

# --- Typewriter tuning ---
@export var chars_per_sec: float = 30.0
@export var start_text := ""

# Pauses
@export var pause_mult_period: float = 6.0
@export var pause_mult_comma: float = 3.0
@export var pause_mult_dash: float = 3.0
@export var pause_mult_newline: float = 6.0

# Voice blip pitch jitter
@export var pitch_jitter: float = 0.07

# Visual wobble
@export var time_passed_multiplier: float = 1.0
@export var scale_multiplier: float = 0.1

# Other
var _guess_object: String = ""

# --- Internal typewriter state ---
var _full_text := ""
var _visible_chars := 0
var _accum := 0.0
var _time_passed := 0.0

# --- Game flow state ---
enum State { Intro, ThemeInput, AIWait, AIDisplay }
var _state: int = State.Intro
var _just_revealed := false
var _game_over := false                     # <— NEW: block further interaction after end

# Theme loop
const THEME_CHAR_MAX := 150
var _has_theme := false
var _player_response_count := 0
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

	# Backend signals
	chat.reply_ready.connect(_on_reply_ready)
	chat.error.connect(_on_chat_error)

	# Button
	continueButton.pressed.connect(_on_continue_pressed)
	continueButton.disabled = true

	# UI setup
	editLabel.visible = false
	editLabel.text = ""
	_set_continue_text("Skip")

	# Make UI transparent before the cinematic
	if uiBox:
		var c := uiBox.modulate
		uiBox.modulate = Color(c.r, c.g, c.b, 0.0)

	# Optional: Rodin hooks you already had…
	rodin.generation_progress.connect(func(s): print("status:", s))
	rodin.generation_failed.connect(func(m): push_error(m))
	rodin.generation_completed.connect(func(path, node):
		if node:
			node.visible = false
			if "freeze" in node:
				node.freeze = true
			node.global_position = objectDrop.global_position
			endObject = node
			var root_scene := get_tree().current_scene
			root_scene.add_child(endObject)
	)

	# Opening cinematic → intro chat
	await _run_opening_cinematic()
	await _start_chat_intro()

func _run_opening_cinematic() -> void:
	if Cam == null or CamStart == null or CamEnd == null:
		if uiBox:
			var tw := create_tween()
			tw.tween_property(uiBox, "modulate:a", 1.0, ui_fade_time) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			await tw.finished
		return

	Cam.global_transform = CamStart.global_transform

	var cam_tw := create_tween().set_parallel(true)
	cam_tw.tween_property(Cam, "global_position", CamEnd.global_position, cam_move_time) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	cam_tw.tween_property(Cam, "global_rotation_degrees", CamEnd.global_rotation_degrees, cam_move_time) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await cam_tw.finished

	if uiBox:
		var tw := create_tween()
		tw.tween_property(uiBox, "modulate:a", 1.0, ui_fade_time) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		await tw.finished

func _start_chat_intro() -> void:
	chat.reset_conversation()
	_state = State.AIWait
	_start_typewriter("Ms. Pea is thinking...")
	continueButton.disabled = true
	chat.send_message(start_text)

func _process(delta: float) -> void:
	_time_passed += delta * time_passed_multiplier

	if _state == State.Intro or _state == State.AIDisplay:
		_typewriter_tick(delta)

	if _is_typing():
		var pWave: float = sin(_time_passed) * scale_multiplier
		var pWaveHalf: float = sin(_time_passed * 0.5) * scale_multiplier
		msPea.scale.y = lerp(msPea.scale.y, msPeaDefaultScale.y + pWave, delta)
		msPea.rotation.z = lerp(msPea.rotation.z, msPeaDefaultRotation.z + pWaveHalf, delta)
	else:
		msPea.scale.y = lerp(msPea.scale.y, msPeaDefaultScale.y, delta)
		msPea.rotation.z = lerp(msPea.rotation.z, msPeaDefaultRotation.z, delta)

# ------------------------------------------------
# Button behavior
# ------------------------------------------------
func _on_continue_pressed() -> void:
	if _game_over:
		return
	if _is_typing():
		_reveal_all()
		_just_revealed = true
		return

	if _just_revealed:
		_just_revealed = false
		_advance_after_reveal()
		return

	match _state:
		State.Intro, State.AIDisplay:
			_goto_theme_input()
		State.ThemeInput:
			_submit_input()
		State.AIWait:
			pass

func _advance_after_reveal() -> void:
	if _game_over:
		return
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
	if _game_over:
		return

	continueButton.disabled = false

	# Extract [secret] → _guess_object and strip it
	var parsed := _extract_guess_and_strip(t)
	if parsed.has("text"):
		t = parsed["text"]

	# WIN/LOSE detection (exact strings)
	var is_win := t.find("YOU WON!!!") != -1
	var is_lose := t.find("YOU LOST!!!") != -1
	if is_win or is_lose:
		playerWon = is_win
		# Show the message fully, then end sequence
		_start_typewriter(t)
		_reveal_all()
		await _handle_game_end(playerWon)
		return

	# Normal display path
	_start_typewriter(t)
	if _state == State.AIWait and not _has_theme:
		_state = State.Intro
	else:
		_state = State.AIDisplay
	_set_continue_text("Skip")

func _on_chat_error(msg: String) -> void:
	if _game_over:
		return
	continueButton.disabled = false
	_start_typewriter("[ERROR] " + msg)
	_state = State.AIDisplay
	_set_continue_text("Skip")

# ------------------------------------------------
# END SEQUENCE
# ------------------------------------------------
func _block_ui_inputs() -> void:
	continueButton.disabled = true
	if editLabel:
		editLabel.editable = false
		editLabel.visible = false

func _end_conversation() -> void:
	# We simply stop sending new messages and ignore further input.
	_game_over = true
	_block_ui_inputs()

func _fade_ui_out() -> void:
	if uiBox == null:
		return
	var tw := create_tween()
	tw.tween_property(uiBox, "modulate:a", 0.0, ui_fade_time) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

func _camera_to_final_point() -> void:
	if Cam == null or finalCamPoint == null:
		return
	var tw := create_tween().set_parallel(true)
	tw.tween_property(Cam, "global_position", finalCamPoint.global_position, cam_move_time) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(Cam, "global_rotation_degrees", finalCamPoint.global_rotation_degrees, cam_move_time) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

func _unfreeze_end_object() -> void:
	if endObject:
		if "freeze" in endObject:
			endObject.freeze = false
		endObject.visible = true

func _handle_game_end(win: bool) -> void:
	if win:
		winSoundPlayer.play()
	else:
		failSoundPlayer.play()
	_end_conversation()
	await _fade_ui_out()
	await _camera_to_final_point()
	_unfreeze_end_object()
	# (Optional) any SFX, confetti, score submit, etc.

# ------------------------------------------------
# Bracket parsing helpers
# ------------------------------------------------
func _extract_guess_and_strip(src: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("\\[([^\\]]+)\\]")

	var match := re.search(src)
	if match:
		var raw_inside := match.get_string(1)
		_guess_object = _sanitize_guess(raw_inside)
		# Kick off 3D gen
		rodin.generate_text_to_glb(_guess_object)

		var stripped := re.sub(src, "", true)
		var ws := RegEx.new()
		ws.compile("\\s{2,}")
		stripped = ws.sub(stripped, " ", true).strip_edges()

		print("GUESS OBJECT IS: " + _guess_object)
		return {"text": stripped, "found": true}

	return {"text": src, "found": false}

func _sanitize_guess(s: String) -> String:
	var lower := s.to_lower()
	var re := RegEx.new()
	re.compile("[^a-z0-9]+")
	return re.sub(lower, "", true)

# ------------------------------------------------
# State transitions
# ------------------------------------------------
func _goto_theme_input() -> void:
	if _game_over:
		return
	_state = State.ThemeInput
	chatLabel.visible = false
	editLabel.visible = true
	editLabel.editable = true
	editLabel.grab_focus()
	_set_continue_text("Ask" if _has_theme else "Send")

func _submit_input() -> void:
	if _game_over:
		return
	var text := editLabel.text.strip_edges()
	if text.length() == 0:
		return
		
	_player_response_count += 1
		
	if _player_response_count == 1:
		editLabel.placeholder_text = "Type in your theme here, then press 'Continue'!"
	elif _player_response_count == 2:
		editLabel.placeholder_text = "Type in a question or guess here, then press 'Continue'!"

	if not _has_theme:
		if _player_response_count >= 2:
			if text.length() > THEME_CHAR_MAX:
				text = text.substr(0, THEME_CHAR_MAX)
			_chosen_theme = text
			_has_theme = true
			chat.set_theme(_chosen_theme)
			_send_ai_and_wait("The theme is: " + _chosen_theme)
			return

	_send_ai_and_wait(text)

func _send_ai_and_wait(outgoing: String) -> void:
	if _game_over:
		return
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
