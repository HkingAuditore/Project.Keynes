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


static func make_dossier_stacked_bar(title: String, segments: Array, total_text: String = "",
		money_icon: bool = false) -> DossierStackedBar:
	var chart := DossierStackedBar.new()
	chart.set_segments(title, segments, total_text, money_icon)
	return chart


static func make_dossier_bar_list(rows: Array, diverging: bool = false,
		selectable: bool = false) -> DossierBarList:
	var chart := DossierBarList.new()
	chart.diverging = diverging
	chart.selectable = selectable
	chart.set_rows(rows)
	return chart


static func make_dossier_radar(axes: PackedStringArray, values: PackedFloat32Array,
		reference: PackedFloat32Array = PackedFloat32Array(),
		accent: Color = UITokens.DOSSIER_OXBLOOD) -> DossierRadarChart:
	var chart := DossierRadarChart.new()
	chart.set_values(axes, values, reference, accent)
	return chart


static func make_dossier_ledger(columns: Array, rows: Array, default_sort: String = "") -> DossierLedgerTable:
	var table := DossierLedgerTable.new()
	table.set_columns(columns, default_sort)
	table.set_rows(rows)
	return table


static func preferred_backend() -> String:
	if ClassDB.class_exists("TauPlot"):
		return "TauPlot"
	if ClassDB.class_exists("EasyChart"):
		return "EasyCharts"
	return "BuiltInSparkline"


static func has_external_backend() -> bool:
	var backend := preferred_backend()
	return backend == "TauPlot" or backend == "EasyCharts"
