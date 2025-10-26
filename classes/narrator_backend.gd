# narrator_backend_gemini.gd
extends Node
class_name NarratorBackend

# --- Config ---
@export var GEMINI_API_KEY: String = "AIzaSyAC8rw6U2LCXK-qhIvdmVEegfQdDSwaPoc"              # put your key in the inspector
@export var MODEL_ID: String = "gemini-2.0-flash"    # ensure this exists for v1beta
@export var system_prompt: String = ""

# Optional generation controls
@export_range(0.0, 2.0, 0.05) var temperature: float = 0.7
@export var max_output_tokens: int = 256

# --- Signals ---
signal reply_ready(text: String)
signal error(message: String)

# --- Internal memory/state ---
var _history: Array = []     # Array of {role:String, parts:Array[{text:String}]}
var _theme: String = ""      # pinned theme context
var _busy := false

# ------------------ Public API ------------------

func reset_conversation() -> void:
	_history.clear()
	_theme = ""
	_busy = false

func set_theme(theme: String) -> void:
	# Store the theme; it will be baked into the system instruction each turn.
	_theme = theme.strip_edges()

func send_message(user_text: String) -> void:
	if GEMINI_API_KEY.strip_edges() == "":
		emit_signal("error", "Missing GEMINI_API_KEY"); return
	if _busy:
		emit_signal("error", "Busy; wait for current reply"); return
	_busy = true

	# Append user message to in-memory history
	_append_user(user_text)

	# Build request
	var url := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s" % [MODEL_ID, GEMINI_API_KEY]

	var sys_text := system_prompt
	if _theme != "":
		sys_text += "\n\nCurrent theme: %s.\nRemember: never reveal the secret object; answer only general questions." % _theme

	var body := {
		"system_instruction": {
			# (role is optional in v1beta; including it is fine)
			"role": "system",
			"parts": [{"text": sys_text}]
		},
		"generationConfig": {
			"temperature": temperature,
			"maxOutputTokens": max_output_tokens
		},
		# Full multi-turn conversation context:
		"contents": _history
	}

	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/json"
		# You could also put the key in a header instead:
		# "x-goog-api-key: %s" % GEMINI_API_KEY
	])

	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		_busy = false
		emit_signal("error", "Failed to start request: %s" % err)
		return

	var res = await http.request_completed
	http.queue_free()

	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	var txt := raw.get_string_from_utf8()

	if code != 200 and code != 201:
		_busy = false
		emit_signal("error", "HTTP %d: %s" % [code, txt])
		return

	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY or not data.has("candidates") or data["candidates"].is_empty():
		_busy = false
		emit_signal("error", "No candidates in response")
		return

	var candidate = data["candidates"][0]
	if not candidate.has("content") or not candidate["content"].has("parts"):
		_busy = false
		emit_signal("error", "Malformed candidate")
		return

	var parts = candidate["content"]["parts"]
	var out := ""
	for p in parts:
		if typeof(p) == TYPE_DICTIONARY and p.has("text"):
			out += str(p["text"])

	# Append assistant reply to memory
	_append_assistant(out)

	_busy = false
	emit_signal("reply_ready", out)

# ------------------ Helpers ------------------

func _append_user(text: String) -> void:
	_history.append({
		"role": "user",
		"parts": [{"text": str(text)}]
	})

func _append_assistant(text: String) -> void:
	_history.append({
		"role": "model",          # Gemini uses "model" for assistant role
		"parts": [{"text": str(text)}]
	})
