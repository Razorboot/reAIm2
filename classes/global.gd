extends Node


## Variables
enum {STATE_SEARCHING, STATE_INTERACTING, STATE_END_INTERACTION, STATE_DISABLED}

var stress_meter: float = 0.0
var dream_shards: int = 0

## Functions
func calculate_dt(dt):
	# The old method
	#var new_dt = 1.0 - (0.25 * dt)
	#new_dt = clamp(new_dt - factor, 0.01, 100.0)
	
	# The new method
	var original_k = 2.0
	var k = 1.0 - pow(original_k, dt)
	k *= -1.5
	return k
