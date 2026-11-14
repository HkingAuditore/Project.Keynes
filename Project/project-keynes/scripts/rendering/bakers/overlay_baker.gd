extends RefCounted
class_name DCOverlayBaker

## Overlay baker boundary.
##
## DataOverlayBaker remains the authoritative overlay implementation. This class
## keeps the existing construction boundary without owning mutable bake state.

func _init(_ctx: DCBakerContext) -> void:
	push_warning("[DCOverlayBaker] not yet implemented — DataOverlayBaker.bake remains the entry")
