# narrator_handler.gd (example)
extends Node

@export var chat: NarratorBackend

func _ready():
	chat.reply_ready.connect(func(t): print("NPC:", t))
	chat.error.connect(func(m): push_error(m))

func _on_user_send(text: String) -> void:
	chat.send_message(text)
