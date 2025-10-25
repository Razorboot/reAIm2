extends Node


## Export Variables
@export var k: float = 2.0 # Intensity
@export var damping: float = 10.0 # constrict spring movement
@export var mass: float = 10.0 # heaviness
@export var vel: Vector3 = Vector3.ZERO # velocity
@export var pos: Vector3 = Vector3.ZERO # origin position
@export var anchor_pos: Vector3 = Vector3.ZERO


## Methods
func update_spring(dt: float) -> void:
	if (dt > 1.0):
		pos = anchor_pos
		vel.x = 0.0
		vel.y = 0.0
		vel.z = 0.0
	else:
		var springForce: Vector3 = -k * (pos - anchor_pos)
		var dampingForce: Vector3 = damping * vel
		var force: Vector3 = springForce - dampingForce
		var acceleration: Vector3 = force/mass
		vel = vel + acceleration * dt
		pos = pos + vel * dt
