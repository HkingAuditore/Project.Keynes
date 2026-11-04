extends RefCounted

## A generator owns its passes and jobs. Their link back is borrowed: retaining
## it would keep the entire world, native worker and textures alive after exit.
## Keep the owner strongly held by the caller while executing a pass or job.
var _generator_ref: WeakRef
var _generator:
	get:
		return _generator_ref.get_ref() if _generator_ref != null else null
	set(value):
		_generator_ref = weakref(value) if value != null else null
