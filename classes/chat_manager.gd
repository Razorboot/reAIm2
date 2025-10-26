extends Control

@export var chat: NarratorBackend
@export var chatLabel: RichTextLabel
@export var editLabel: TextEdit
@export var continueButton: Button
@export var msPea: Node3D

@export var chars_per_sec: float = 30.0
@export var start_text := ""

var _full_text := ""
var _visible_chars := 0
var _accum := 0.0
var _time_passed := 0.0
var _message_count: int = 0
var _chat_state := "Intro"
var continue_just_pressed := false

@export var time_passed_multiplier: float
@export var scale_multiplier: float

var msPeaDefaultScale: Vector3
var msPeaDefaultRotation: Vector3

func _ready() -> void:
	if chat == null:
		push_error("Chat node not assigned"); return
	
	msPeaDefaultScale = Vector3(msPea.scale.x, msPea.scale.y, msPea.scale.z)

	# Connect signals to your own methods
	chat.reply_ready.connect(_on_reply_ready)
	chat.error.connect(_on_chat_error)
	chat.send_message("I just started up this game! Who are you and what am I supposed to do?")

	if continueButton:
		continueButton.pressed.connect(_on_continue_pressed)

func _on_user_send(text: String) -> void:
	chat.send_message(text)
	_start_typewriter("Ms. Pea is thinking...") # optional “thinking” placeholder

# <-- This is YOUR function that gets the text "t"
func _on_reply_ready(t: String) -> void:
	_message_count += 1
	continueButton.text = "Skip"
	_start_typewriter(t)

func _on_chat_error(msg: String) -> void:
	_start_typewriter("[ERROR] " + msg)

# --- (optional) typewriter reveal into your Label ---
func _start_typewriter(t: String) -> void:
	_full_text = t
	_visible_chars = 0
	_accum = 0.0
	if chatLabel:
		chatLabel.text = ""  # start blank

func _process(delta: float) -> void:
	_time_passed += delta * time_passed_multiplier
	
	if chatLabel == null: return
	
	if _visible_chars < _full_text.length():
		_accum += delta
		var step := int(chars_per_sec * _accum)
		if step > 0:
			_accum = 0.0
			_visible_chars = clamp(_visible_chars + step, 0, _full_text.length())
			chatLabel.text = _full_text.substr(0, _visible_chars)
		
		var pWave: float = sin(_time_passed) * scale_multiplier
		var pWaveHalf: float = sin(_time_passed * 0.5) * (scale_multiplier)
		msPea.scale.y = lerp(msPea.scale.y, msPeaDefaultScale.y + pWave, delta)
		msPea.rotation.z = lerp(msPea.rotation.z, msPeaDefaultRotation.z + pWaveHalf, delta)
	else:
		msPea.scale.y = lerp(msPea.scale.y, msPeaDefaultScale.y, delta)
		msPea.rotation.z = lerp(msPea.rotation.z, msPeaDefaultRotation.z, delta)
		
		if _chat_state == "Intro":
			_chat_state = "Theme"

func _on_continue_pressed() -> void:
	# reveal rest instantly
	if _chat_state == "Intro":
		if continueButton.text == "Skip":
			chatLabel.text = _full_text
			_accum = 1.0
		else:
			chatLabel.visible = false
			editLabel.visible = true
