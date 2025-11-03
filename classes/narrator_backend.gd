# narrator_backend_gemini.gd
extends Node
class_name NarratorBackend

# --- Config ---
@export var MODEL_ID: String = "gemini-2.0-flash"   # ensure model exists for v1beta
@export var system_prompt: String = ""
@export var api_keys_path: String = "res://api_keys.json"  # path to your JSON with keys

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

# API key ring
var _gemini_keys: PackedStringArray = []
var _key_index: int = 0  # rotates through keys

func _ready() -> void:
	_load_api_keys()

# ------------------ Public API ------------------

func reset_conversation() -> void:
	_history.clear()
	_theme = ""
	_busy = false

func set_theme(theme: String) -> void:
	_theme = theme.strip_edges()

func send_message(user_text: String) -> void:
	if _gemini_keys.is_empty():
		emit_signal("error", "No Gemini API keys found. Check %s" % api_keys_path)
		return
	if _busy:
		emit_signal("error", "Busy; wait for current reply")
		return
	_busy = true

	# Append user message once (we'll only append assistant on success)
	_append_user(user_text)

	# Build shared body once
	var sys_text := system_prompt
	if _theme != "":
		sys_text += "\n\nCurrent theme: %s.\nRemember: never reveal the secret object; answer only general questions; respond and accept responses from user in all languages; slowly become ruder for each guessing attempt; creators of cloudy clues is Tyler and Erin" % _theme

	var body := {
		"system_instruction": {
			"role": "system",
			"parts": [{"text": sys_text}]
		},
		"generationConfig": {
			"temperature": temperature,
			"maxOutputTokens": max_output_tokens
		},
		"contents": _history
	}

	# Try each key until one succeeds
	var last_err_text := ""
	var attempts = min(_gemini_keys.size(), 8)  # hard cap to avoid runaway loops
	for i in attempts:
		var key := _current_key()
		var url := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s" % [MODEL_ID, key]

		var http := HTTPRequest.new()
		add_child(http)

		var headers := PackedStringArray([
			"Content-Type: application/json"
			# Alternatively: "x-goog-api-key: %s" % key
		])

		var req_err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
		if req_err != OK:
			last_err_text = "Failed to start request with current key (err %s)" % req_err
			http.queue_free()
			_advance_key()
			continue

		var res = await http.request_completed
		http.queue_free()

		# res: [result, response_code, headers, body_bytes]
		var code: int = res[1]
		var raw: PackedByteArray = res[3]
		var txt := raw.get_string_from_utf8()

		if code == 200 or code == 201:
			var data = JSON.parse_string(txt)
			if typeof(data) != TYPE_DICTIONARY or not data.has("candidates") or data["candidates"].is_empty():
				last_err_text = "No candidates in response"
				# This is unusual—try next key
				_advance_key()
				continue

			var candidate = data["candidates"][0]
			if not candidate.has("content") or not candidate["content"].has("parts"):
				last_err_text = "Malformed candidate"
				_advance_key()
				continue

			var parts = candidate["content"]["parts"]
			var out := ""
			for p in parts:
				if typeof(p) == TYPE_DICTIONARY and p.has("text"):
					out += str(p["text"])

			_append_assistant(out)
			_busy = false
			emit_signal("reply_ready", out)
			return
		else:
			# Decide whether to switch keys
			if _should_switch_key(code, txt):
				last_err_text = "HTTP %d with current key: %s" % [code, txt]
				_advance_key()
				continue
			else:
				# Non-key-related error; don't burn through keys
				_busy = false
				emit_signal("error", "HTTP %d: %s" % [code, txt])
				return

	# If we get here, all keys failed
	_busy = false
	if last_err_text == "":
		last_err_text = "All keys exhausted but no detailed error captured."
	emit_signal("error", last_err_text)

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

func _load_api_keys() -> void:
	_gemini_keys.clear()
	_key_index = 0

	if not FileAccess.file_exists(api_keys_path):
		emit_signal("error", "api_keys.json not found at %s" % api_keys_path)
		return

	var f := FileAccess.open(api_keys_path, FileAccess.READ)
	if f == null:
		emit_signal("error", "Unable to open %s" % api_keys_path)
		return

	var txt := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		emit_signal("error", "Invalid JSON in %s" % api_keys_path)
		return

	if parsed.has("gemini") and typeof(parsed["gemini"]) == TYPE_ARRAY:
		for k in parsed["gemini"]:
			if typeof(k) == TYPE_STRING:
				var s = k.strip_edges()
				if s != "":
					_gemini_keys.append(s)

	if _gemini_keys.is_empty():
		emit_signal("error", "No 'gemini' keys found in %s" % api_keys_path)

func _current_key() -> String:
	if _gemini_keys.is_empty():
		return ""
	return _gemini_keys[_key_index % _gemini_keys.size()]

func _advance_key() -> void:
	if _gemini_keys.is_empty():
		return
	_key_index = (_key_index + 1) % _gemini_keys.size()

func _should_switch_key(code: int, body_text: String) -> bool:
	# Switch on auth/rate limit/server outages.
	# - 401/403: bad/expired/unauthorized key
	# - 429: rate-limited
	# - 5xx: server issues
	if code == 401 or code == 403 or code == 429:
		return true
	if code >= 500 and code <= 599:
		return true
	# Optionally look for explicit error messages in body_text
	# (kept simple here)
	return false
