// annual_sheet_tear.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────────
// 年度报告「长纸」的蒙版纵向采样 —— 纸场与投影共用同一份轮廓与同一套行号算术。
//
// 蒙版位图现在烘的是**四边都撕开**的一张纸（tools/ui/build_paper_tear_mask.py）：
//
//   rows [0, CAP_ROWS)              源图真实的上撕口，横跨整幅纸宽一遍
//   rows [CAP_ROWS, H-CAP_ROWS)     左右两道撕口，做了周期化，可以纵向镜像平铺
//   rows [H-CAP_ROWS, H)            源图真实的下撕口
//   其中纸面的名义上沿落在第 CAP_FAR 行（= 纸外留白），名义下沿落在 H - CAP_FAR。
//
// 纸是一件有限高的实物：它只有一个头、一个尾。所以两端**1:1 直接取位图**，
// 只有中段需要平铺 —— 纸有八千像素，蒙版只有九百，直接拉伸会把撕口轮廓抻成
// 一条几乎没有起伏的曲线，"手撕"立刻变"机切"。
//
// 早先两端是程序化噪声撕的，因为那时纸上下出血、头尾都在屏幕外，位图里那两条边
// 被构建脚本当圆角裁掉了（old: VERTICAL_BAND = 0.62）。纸变成实物之后那两条边
// 第一次出现在读者眼前，程序化噪声和左右两边的真实纤维一比就露馅 ——
// 所以改成四条边全走位图。
// ─────────────────────────────────────────────────────────────────────────────

// seed 由调用方传入（纸场用的是自己的 seed uniform，投影是另一个材质实例）。
float annual_tear_hash(vec2 p, float tear_seed) {
	p = fract(p * vec2(123.34, 456.21) + tear_seed);
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float annual_tear_noise(vec2 p, float tear_seed) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = annual_tear_hash(i, tear_seed);
	float b = annual_tear_hash(i + vec2(1.0, 0.0), tear_seed);
	float c = annual_tear_hash(i + vec2(0.0, 1.0), tear_seed);
	float d = annual_tear_hash(i + vec2(1.0, 1.0), tear_seed);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 纸层第 layer_y 行 → 蒙版纹理的 v（0..1）。
//
// layer_y    纸层坐标（0 = 纸层上沿，含 cap_pad 留白）
// layer_h    纸层高度
// tex_h      蒙版原生高度（行）
// cap_rows   蒙版上下两端各占多少行（构建脚本 CAP_ROWS）
// cap_pad    纸层在纸面名义边缘之外多留的像素（AnnualReportTokens.cap_pad）
// cap_edge   蒙版顶行到纸面名义上沿的行数（构建脚本 CAP_FAR）
//
// 三段：
//   纸头  纸层第 cap_pad 行必须落在蒙版第 cap_edge 行 —— 那时纸层上沿正对着
//         那张纸上真实的撕口。于是 1:1 段的偏移 shift = cap_edge - cap_pad，
//         1:1 段在层坐标里只有 cap_rows - shift 行厚（比 cap_rows 薄，因为
//         纸层留白比蒙版的纸外留白窄）。中段的折缝正好接在这个行号上。
//   中段  镜像平铺，左右两道撕口以接近 1:1 的速度往下走。
//   纸尾  对称。
//
// 两处容易写错的地方：
//   1) 折数要除以 band * 2，因为一次折叠要走一个来回（去 band 行、再回 band 行）。
//      少除这个 2，撕口会被纵向压扁一倍，豁口变成锯齿。
//   2) 折数取「整数 + 半」：下界落在折缝（fold = 0）、上界落在折峰（fold = 1），
//      与两端 1:1 的切口严丝合缝，接缝处既不跳行也不闪。
float annual_sheet_mask_v(float layer_y, float layer_h, float tex_h,
		float cap_rows, float cap_pad, float cap_edge) {
	float cap = clamp(cap_rows, 1.0, tex_h * 0.40);
	float band = max(tex_h - cap * 2.0, 1.0);
	float edge = clamp(cap_edge, 0.0, tex_h * 0.45);
	float shift = max(edge - clamp(cap_pad, 0.0, tex_h * 0.45), 0.0);
	float hard = max(cap - shift, 1.0);

	if (layer_y < hard) {
		return clamp(layer_y + shift, 0.0, tex_h) / tex_h;
	}
	if (layer_y > layer_h - hard) {
		return clamp(tex_h - cap + (layer_y - (layer_h - hard)), 0.0, tex_h) / tex_h;
	}
	float span = max(layer_h - hard * 2.0, 1.0);
	float u = (layer_y - hard) / span;
	float folds = max(floor(span / max(band * 2.0, 1.0)) + 0.5, 0.5);
	float fold = 1.0 - abs(fract(u * folds) * 2.0 - 1.0);
	return clamp(cap + fold * band, 0.0, tex_h - 1.0) / tex_h;
}

// ── 以下只在蒙版缺席时启用（has_mask = 0）─────────────────────────────────
// 位图加载失败时的兜底：两端用程序化噪声撕，总比露出一条机切直边强。
// 正常路径永远走不到这里 —— 纸、投影、页眉遮罩都挂在同一张 PNG 上。

// 这一列（纸层坐标 x）上，上端/下端的撕口相对名义纸缘咬进去多深（像素）。
float annual_sheet_cap_bite(float x_px, float width_px, float depth_px, float tear_seed) {
	float x01 = x_px / max(width_px, 1.0);
	float wobble = (annual_tear_noise(vec2(x01 * 8.2, tear_seed * 3.1), tear_seed) - 0.5) * 1.10
			+ (annual_tear_noise(vec2(x01 * 43.0, tear_seed + 17.0), tear_seed) - 0.5) * 0.95
			+ (annual_tear_noise(vec2(x01 * 177.0, tear_seed + 31.0), tear_seed) - 0.5) * 0.34;
	float bite = depth_px * clamp(0.42 + wobble * 0.45, -0.22, 1.0);
	bite += step(0.86, annual_tear_noise(vec2(x01 * 24.0, tear_seed + 43.0), tear_seed)) * depth_px * 0.55;
	bite += (annual_tear_hash(vec2(floor(x_px), tear_seed + 7.0), tear_seed) - 0.5) * 3.2;
	return bite;
}
