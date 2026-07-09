extends RefCounted
class_name ChartAdapter

## 第三方图表库隔离层。
## 当前默认返回项目自绘 SparklineChart；后续验证 Easy Charts / TauPlot 后，
## 只需要在这里替换具体控件，不让业务 UI 依赖插件 API。


static func make_sparkline(title: String, values: Array, accent: Color = UITokens.ACCENT) -> Control:
	var chart := SparklineChart.new()
	chart.set_data(title, values, accent)
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
