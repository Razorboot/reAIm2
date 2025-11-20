extends Control

@export var next_scene_path: String
var progress := [0.0] # Threaded loader requires an array for progress

# Animation variables
@onready var icon        = $Icon
@onready var progress_bar = $ProgressBar
@onready var label       = $Label
@onready var cloudy_txt  = $"Cloudy"
@onready var clues_txt = $Clues

var sway_speed     := 1.5
var sway_angle     := 5.0
var scale_variation := .02

# Fade variables
@onready var fade_rect   = $FadeRect  # Fullscreen ColorRect covering screen
var fade_speed     := 2.0
var is_fading_out  := false

func _ready() -> void:
	# Ensure the fade rect is fully transparent at start
	if fade_rect:
		fade_rect.modulate.a = 0.0
	load_next_scene()
	
func fade_out():
	if not fade_rect:
		return
	while fade_rect.modulate.a < 1.0:
		fade_rect.modulate.a = min(fade_rect.modulate.a + fade_speed * get_process_delta_time(), 1.0)
		await get_tree().process_frame


func load_next_scene() -> void:
	var err = ResourceLoader.load_threaded_request(next_scene_path)
	if err != OK:
		push_error("Failed to start threaded load for: " + next_scene_path)
		return

	while true:
		var status = ResourceLoader.load_threaded_get_status(next_scene_path, progress)
		# Update UI
		if progress_bar:
			progress_bar.value = progress[0] * 100
		if label:
			label.text = "Loading... " + str(int(progress[0] * 100)) + "%"

		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				is_fading_out = true
				await fade_out()
				var scene = ResourceLoader.load_threaded_get(next_scene_path)
				get_tree().change_scene_to_packed(scene)
				break

			ResourceLoader.THREAD_LOAD_FAILED:
				push_error("Failed to load scene: " + next_scene_path)
				break

		await get_tree().process_frame

func _process(_delta: float) -> void:
	if icon:
		var time = Time.get_ticks_msec() / 1000.0
		var angle = sin(time * sway_speed) * sway_angle
		var scale_factor = .25 + sin(time * 2.0) * scale_variation
		

		icon.rotation_degrees = angle
		icon.scale = Vector2(scale_factor, scale_factor)
		
	if cloudy_txt:
		var time = Time.get_ticks_msec() / 1000.0
		var angle = sin(time / sway_speed) * sway_angle
		var scale_factor = 1 + sin(time * 2.0) * scale_variation
		

		cloudy_txt.rotation_degrees = angle
		cloudy_txt.scale = Vector2(scale_factor, scale_factor)
		
	if clues_txt:
		var time = Time.get_ticks_msec() / 1000.0
		var angle = sin(time * sway_speed) * sway_angle
		var scale_factor = sin(time * 2.0) * 0.5 + 1.0

		clues_txt.rotation_degrees = angle
		clues_txt.scale = Vector2(scale_factor, scale_factor)

	if is_fading_out and fade_rect:
		fade_rect.modulate.a = min(fade_rect.modulate.a + fade_speed * _delta, 1.0)
