extends RefCounted
class_name ChartAdapter

const SparklineScene := preload("res://scenes/ui/sparkline_chart.tscn")

## 第三方图表库隔离层。
## 当前默认返回项目自绘 SparklineChart；后续验证 Easy Charts / TauPlot 后，
## 只需要在这里替换具体控件，不让业务 UI 依赖插件 API。


static func make_sparkline(
		title: String,
		values: Array,
		accent: Color = UITokens.ACCENT,
		min_value: float = NAN,
		max_value: float = NAN,
		window_size: int = 0,
		value_text: String = ""
) -> Control:
	var chart := SparklineScene.instantiate() as SparklineChart
	chart.set_data(title, values, accent, min_value, max_value, window_size, value_text)
	return chart


static func preferred_backend() -> String:
	if ClassDB.class_exists("TauPlot"):
		return "TauPlot"
	if ClassDB.class_exists("EasyChart"):
		return "EasyCharts"
	return "BuiltInSparkline"


static func has_external_backend() -> bool:
	var backend := preferred_backend()
	return backend == "TauPlot" or backend == "EasyCharts"
