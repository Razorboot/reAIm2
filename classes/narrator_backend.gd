# narrator_backend_gemini.gd
extends Node
class_name NarratorBackend

@export var GEMINI_API_KEY: String = "AIzaSyAC8rw6U2LCXK-qhIvdmVEegfQdDSwaPoc"
@export var MODEL_ID: String = "gemini-2.0-flash" # or "gemini-1.5-flash-001"
@export var system_prompt: String = "You are a friendly NPC named Ms. Pea who is witty, funny, and aligned to gen z humor. You're a SASS queen and you're a fan of brawlstars.
The player will give you a theme at one point. After the player tells you what the theme is, your job is to pick a simple object related to that theme. 
You cannot tell the player what the object is, but you can answer general questions about the object that the player asks you, but you cannot give hints about anything too specific that would allow the player to guess the object easily.
The object should also be one word long or the name of some media/existing IP. Keep your messages short and concise!"

signal reply_ready(text: String)
signal error(message: String)

func send_message(user_text: String) -> void:
	# Build request
	var url := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s" % [MODEL_ID, GEMINI_API_KEY]

	var body := {
		"system_instruction": {"parts":[{"text": system_prompt}]},
		"contents": [
			{"role":"user","parts":[{"text": user_text}]}
		]
	}

	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/json"
		# You can also pass the key as a header:
		# "x-goog-api-key: %s" % GEMINI_API_KEY
	])

	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_error("Gemini request start failed: %s" % err)
		emit_signal("error", "Failed to start request"); http.queue_free(); return

	var res = await http.request_completed
	http.queue_free()

	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	var txt := raw.get_string_from_utf8()

	if code != 200 and code != 201:
		push_error("HTTP %d: %s" % [code, txt])
		emit_signal("error", "HTTP %d: %s" % [code, txt])
		return

	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY or not data.has("candidates") or data["candidates"].is_empty():
		emit_signal("error", "No candidates in response")
		return

	var candidate = data["candidates"][0]
	if not candidate.has("content") or not candidate["content"].has("parts"):
		emit_signal("error", "Malformed candidate")
		return

	var parts = candidate["content"]["parts"]
	var out := ""
	for p in parts:
		if typeof(p) == TYPE_DICTIONARY and p.has("text"):
			out += str(p["text"])
	emit_signal("reply_ready", out)
