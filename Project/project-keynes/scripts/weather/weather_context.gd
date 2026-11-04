extends RefCounted

## WeatherSystem owns these helpers. Borrow the reverse link so destroying the
## world releases the weather helpers, DataCore worlds and native worker too.
var _weather_system_ref: WeakRef
var _weather_system:
	get:
		return _weather_system_ref.get_ref() if _weather_system_ref != null else null
	set(value):
		_weather_system_ref = weakref(value) if value != null else null
