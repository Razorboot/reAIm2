# narrator_backend_gemini.gd
extends Node
class_name NarratorBackend

# --- Keys & model ---
@export var GEMINI_API_KEYS: Array[String] = [
	"AIzaSyBTsVuzojRo1fgYXiEblVm1PyvZ-VWcsY8",
	"AIzaSyBeE2qfu26OvZdkoPaVW_Pi7pINUkyGsdE",
	"AIzaSyDa4R4rDbfv7t063P6h6f8qErejo9tEq78",
	"AIzaSyAC8rw6U2LCXK-qhIvdmVEegfQdDSwaPoc"
]   # <— fill in multiple keys here
@export var MODEL_ID: String = "gemini-2.5-flash" # keep the working model ID
@export var system_prompt: String = """
You are a friendly NPC named Ms. Pea who is a cheerful, but sometimes witty and 'sassy' but you keep your messages concise and you don't respond in markdown -- you're also a huge supercell video game fan, you play brawl stars and love the character jacky (since she hops) and you are a bunny (just as a fun fact)! You will ask the player to pick a theme for a game, and based on the theme you will pick an object that is easily generatable. The object will be one word and it will be the name of some existing IP or media category of that theme. You absolutely cannot tell the player what the object you picked is, but you can answer GENERAL questions (not specific) questions about the object when asked. You cannot give any hints about specifics that relate to the object which would allow the player to easily guess what the object is. If they do ask something specific or ask for the answer, redirect the question by firmly saying you cannot answer a question like that.
""".strip_edges()

# --- Soft memory (persists across key rotation) ---
var _theme: String = ""
var _history: Array = []  # Google Gemini "contents" array: [{role, parts:[{text}]} ...]
var _active_key_index: int = 0

signal reply_ready(text: String)
signal error(message: String)

# ----------------------------------------------------
# Public API
# ----------------------------------------------------
func reset_conversation() -> void:
	_history.clear()
	_theme = ""

func set_theme(t: String) -> void:
	_theme = t

func set_api_keys(keys: Array) -> void:
	GEMINI_API_KEYS = keys.duplicate()
	_active_key_index = 0

func get_active_key_index() -> int:
	return _active_key_index

func force_key_index(i: int) -> void:
	if GEMINI_API_KEYS.is_empty():
		_active_key_index = 0
	else:
		_active_key_index = clamp(i, 0, GEMINI_API_KEYS.size()-1)

# ----------------------------------------------------
# Core send (with key rotation)
# ----------------------------------------------------
func send_message(user_text: String) -> void:
	if GEMINI_API_KEYS.is_empty():
		emit_signal("error", "No API keys configured"); return

	# Build conversation contents (history + this user turn)
	var contents := _history.duplicate()
	# Optionally inject a compact “memory header” for theme on each user turn
	if _theme != "":
		contents.append({"role":"user","parts":[{"text":"(Theme reminder: " + _theme + ")"}]})
	contents.append({"role":"user","parts":[{"text": user_text}]})

	# We’ll attempt each key at most once in a round-robin pass
	var attempts: float = min(GEMINI_API_KEYS.size(), 6)
	for _i in attempts:
		var key := GEMINI_API_KEYS[_active_key_index]
		var ok := await _try_request_with_key(key, contents)
		if ok:
			return
		# rotate to next key and try again (for quota/limit/5xx)
		_active_key_index = (_active_key_index + 1) % GEMINI_API_KEYS.size()

	# If we end up here, all keys failed this round
	emit_signal("error", "All API keys failed (quota/limit or network).")

# ----------------------------------------------------
# Single attempt with one key
# ----------------------------------------------------
func _try_request_with_key(api_key: String, contents: Array) -> bool:
	var url := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s" % [MODEL_ID, api_key]

	var body := {
		"system_instruction": {"parts":[{"text": system_prompt}]},
		"contents": contents
	}

	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		remove_child(http); http.queue_free()
		emit_signal("error", "Failed to start request: %s" % err)
		return false

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	var txt := raw.get_string_from_utf8()

	# Quota/limit or transient failures → return false so caller can rotate keys.
	if code == 429 or code == 403 or code == 402 or (code >= 500 and code <= 599):
		print("Gemini key index %d failed with %d; rotating..." % [_active_key_index, code])
		return false

	# Other non-OK → surface error (don’t rotate further unless you want to).
	if code != 200 and code != 201:
		emit_signal("error", "HTTP %d: %s" % [code, txt])
		return false

	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY or not data.has("candidates") or data["candidates"].is_empty():
		emit_signal("error", "No candidates in response")
		return true # treat as handled (don’t rotate)

	var candidate = data["candidates"][0]
	if not candidate.has("content") or not candidate["content"].has("parts"):
		emit_signal("error", "Malformed candidate")
		return true

	var parts = candidate["content"]["parts"]
	var out := ""
	for p in parts:
		if typeof(p) == TYPE_DICTIONARY and p.has("text"):
			out += str(p["text"])

	# Append the successful exchange to memory
	# (We already appended the user turn when building `contents` for the request,
	# so add only the model turn to `_history` here.)
	_history = contents.duplicate()
	_history.append({"role":"model","parts":[{"text": out}]})

	emit_signal("reply_ready", out)
	return true
