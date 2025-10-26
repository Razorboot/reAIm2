extends Control

@export var chat: NarratorBackend
@export var chatLabel: Label
@export var editLabel: TextEdit
@export var continueButton: Button

@export var chars_per_sec: float = 60.0
@export var start_text := ""

var _full_text := ""
var _visible_chars := 0
var _accum := 0.0
var _message_count: int = 0
var _chat_state := "Intro"
var continue_just_pressed := false

func _ready() -> void:
	if chat == null:
		push_error("Chat node not assigned"); return

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
	if chatLabel == null: return
	
	if _visible_chars < _full_text.length():
		_accum += delta
		var step := int(chars_per_sec * _accum)
		if step > 0:
			_accum = 0.0
			_visible_chars = clamp(_visible_chars + step, 0, _full_text.length())
			chatLabel.text = _full_text.substr(0, _visible_chars)
	else:
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
