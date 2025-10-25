extends CharacterBody3D


## Constants
const SPEED: float = 3.0
const MIN_SPEED: float = 0.3
const JUMP_VELOCITY: float = 4.5

const MOTION_INTENSITY: float = 0.07
const HALF_MOTION_INTENSITY: float = 0.07 * 0.5
const MOTION_SPEED: float = 12.0
const HALF_MOTION_SPEED: float = MOTION_SPEED * 0.5


## References
@export var Camera: Camera3D
@export var Neck: Node3D
@export var Spine: Node3D

@export var GuiControl: Control
@export var ResponseLabel: Label

@export var Interactor: Node3D


## Variables
var velocity_goal: Vector3 = Vector3.ZERO
var mouse_position_goal: Vector2 = Vector2.ZERO
var mouse_position: Vector2 = Vector2.ZERO
var accumulated_time: float = 0.0
var global_spine_interpolation_goal: Vector3 = Vector3.ZERO

var is_locked: bool = false
var mouse_locked: bool = false
var last_mouse_locked: bool = false


## Input
func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	global_spine_interpolation_goal = global_position + Vector3(0.0, 1.673, 0.0)
	
	# Setup
	Neck.damping = 5.0

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_locked == false:
		mouse_position_goal += event.relative

## Processes
func _process(delta: float) -> void:
	var fixed_delta: float = Global.calculate_dt(delta)
	var mouse_delta = fixed_delta * 10.0
	accumulated_time += fixed_delta
	
	global_spine_interpolation_goal = global_spine_interpolation_goal.lerp(global_position + Vector3(0.0, 1.673, 0.0), fixed_delta * 25.0)
	Spine.global_position = global_spine_interpolation_goal
	
	# Camera Movement
	mouse_position = lerp(mouse_position, mouse_position_goal, mouse_delta)
	Neck.rotation.y = mouse_position.x * -0.005
	Camera.rotation.x = mouse_position.y * -0.005
	
	# Camera Motion
	if is_on_floor() and (absf(velocity.x) + absf(velocity.z) > MIN_SPEED):
		Neck.anchor_pos.x = sin(accumulated_time * HALF_MOTION_SPEED) * HALF_MOTION_INTENSITY
		Neck.anchor_pos.y = cos(accumulated_time * MOTION_SPEED) * MOTION_INTENSITY
	
	Neck.update_spring(fixed_delta * 20.0)
	Camera.position.x = Neck.pos.x
	Neck.position.y = Neck.pos.y
	
	Camera.rotation.x += (Neck.pos.y * -MOTION_INTENSITY)
	Camera.rotation.z = (Neck.pos.x * HALF_MOTION_INTENSITY)
	
	# Exit
	if Input.is_action_just_pressed("exit"):
		get_tree().quit()

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor() and is_locked == false:
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector("walk_left", "walk_right", "walk_up", "walk_down")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if is_locked == true:
		direction = Vector3.ZERO
		
	if direction.length() > 0.0:
		var camera_basis: Basis = Neck.global_transform.basis  # The camera's basis
		var forward: Vector3 = camera_basis.z.normalized()  # Camera's forward direction
		var right: Vector3 = camera_basis.x.normalized()     # Camera's right direction
		
		# Project the input direction onto the camera's local basis
		var direction_relative_to_camera: Vector3 = (right * direction.x) + (forward * direction.z)
		direction_relative_to_camera = direction_relative_to_camera.normalized()  # Normalize for consistent speed
		
		# Apply the direction to the velocity goal
		velocity_goal.x = direction_relative_to_camera.x * SPEED
		velocity_goal.z = direction_relative_to_camera.z * SPEED
	else:
		velocity_goal.x = 0
		velocity_goal.z = 0
	
	var fixed_delta: float = Global.calculate_dt(delta * 10.0)
	
	## Character Movement
	velocity.x = lerpf(velocity.x, velocity_goal.x, fixed_delta)
	velocity.z = lerpf(velocity.z, velocity_goal.z, fixed_delta)

	## Update
	move_and_slide()
