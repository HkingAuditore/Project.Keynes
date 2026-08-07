class_name IdeologyProfile
extends Resource

@export_range(0, 64, 1) var ideology_capacity: int = 6
@export_range(0, 64, 1) var national_spirit_capacity: int = 3
@export_range(3, 3, 1) var offer_choice_count: int = 3
@export_range(0, 2147483647, 1) var offer_cost_q16: int = 65536
@export_range(1, 1000000, 1) var max_commands_per_slice: int = 4096
