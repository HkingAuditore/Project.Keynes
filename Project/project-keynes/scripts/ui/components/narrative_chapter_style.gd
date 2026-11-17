extends RefCounted

const CutTagTexture: Texture2D = preload("res://assets/ui/paper_aux_v1/cut_tag_v1.tres")

const ChapterEmblemsTexture: Texture2D = preload("res://assets/ui/annual_chronicle/chronicle_chapter_emblems.png")

const TAG_TO_EMBLEM_INDEX := {
	"climate": 7,
	"drought": 7,
	"cold": 7,
	"flood": 4,
	"geography": 4,
	"ocean": 6,
	"maritime": 6,
	"market": 6,
	"commerce": 6,
	"trade": 6,
	"industry": 3,
	"innovation": 5,
	"discovery": 5,
	"prospecting": 7,
	"chain": 5,
	"society": 2,
	"unrest": 2,
	"agriculture": 1,
	"harvest": 1,
	"prosperity": 0,
}

static func _make_cut_tag_style(tint: Color = Color.WHITE) -> StyleBoxTexture:
	var st := StyleBoxTexture.new()
	st.texture = CutTagTexture
	st.texture_margin_left = 18.0
	st.texture_margin_top = 24.0
	st.texture_margin_right = 26.0
	st.texture_margin_bottom = 16.0
	st.content_margin_left = 12.0
	st.content_margin_top = 5.0
	st.content_margin_right = 16.0
	st.content_margin_bottom = 5.0
	st.modulate_color = tint
	return st


static func _chapter_emblem_for_tags(tags: Array) -> Texture2D:
	var idx := 0
	for t in tags:
		var k := String(t).to_lower()
		if TAG_TO_EMBLEM_INDEX.has(k):
			idx = int(TAG_TO_EMBLEM_INDEX[k])
			break
	var atlas := AtlasTexture.new()
	atlas.atlas = ChapterEmblemsTexture
	var col_idx := idx % 3
	var row_idx := idx / 3
	# 3x3 网格，格边长按纹理实际宽度换算——贴图降分辨率后写死 512 会切错位。
	var cell := float(ChapterEmblemsTexture.get_width()) / 3.0
	atlas.region = Rect2(float(col_idx) * cell, float(row_idx) * cell, cell, cell)
	return atlas
