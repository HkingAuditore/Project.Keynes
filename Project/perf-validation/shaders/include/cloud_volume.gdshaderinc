// cloud_volume.gdshaderinc
// 云的散射原语。
//
// 这里**没有 raymarch**，而且刻意不做。全屏迷雾层沿视线积分的代价（每像素几百次
// 噪声）远超它带来的观感收益：俯视地图看到的本来就只是云海的**顶面**，云内部的
// 光路细节根本看不见。真正决定观感的是顶面的形状、受光和自阴影，这些用高度场 +
// 几个探针就能拿到。
//
// 所以留下的是「不需要积分就能用」的那部分散射模型：相函数、多重散射衰减、
// Beer 的双指数近似。噪声本身在 cloud_noise.gdshaderinc。

#ifndef PK_CLOUD_VOLUME_INC
#define PK_CLOUD_VOLUME_INC

#define PK_CLOUD_PI 3.14159265359

// Henyey-Greenstein 相函数。g > 0 = 前向散射：视线朝着太阳时云缘透光发亮
// （银边就是这么来的，不是靠给边缘手动加亮度）。
float cloud_hg(float cos_theta, float g) {
	float g2 = g * g;
	float denom = 1.0 + g2 - 2.0 * g * cos_theta;
	denom = max(denom, 1e-4);
	return (1.0 - g2) / (4.0 * PK_CLOUD_PI * denom * sqrt(denom));
}

// 实用相函数：前向瓣（银边）+ 弱后向瓣（背光轮廓辉光）+ 各向同性底。
//
// 单瓣 HG 在侧光/背光方向会掉到前向峰值的 1/30。俯视地图时散射角基本就跟着太阳
// 高度角走，直接用单瓣会让云在太阳一低的时候整片发黑。真云不会 —— 高阶散射早就
// 把方向性抹平了，所以要掺一个各向同性底。这不是为了好看作弊，而是单次散射相函数
// 本来就不该单独代表整朵云。
float cloud_phase(float cos_theta, float g) {
	float fwd = cloud_hg(cos_theta, g);
	float back = cloud_hg(cos_theta, -g * 0.35);
	float iso = 1.0 / (4.0 * PK_CLOUD_PI);
	return mix(mix(fwd, back, 0.22), iso, 0.42);
}

// 多重散射透过率：两个不同消光率的指数叠加。
//
// 单指数 Beer 会让阴影一路压到全黑，那是「烟」不是「云」。真云的高阶散射会把光
// 抹进阴影里，衰减尾巴比单指数长得多。用一个快项 + 一个慢项去近似那条尾巴，是
// 不做体积积分时能拿到的最便宜的「通透感」。
float cloud_beer_ms(float depth) {
	return 0.78 * exp(-depth) + 0.22 * exp(-depth * 0.25);
}

// Powder（糖粉效应）：云的迎光**薄**边因为多重散射不足反而偏暗。
// 纯 Beer 会把边缘算得过亮，加了这一项云缘才不像发光的棉花糖。
float cloud_powder(float density, float weight) {
	return mix(1.0, 1.0 - exp(-density * 3.2), weight);
}

float cloud_remap(float v, float lo, float hi) {
	return clamp((v - lo) / max(hi - lo, 1e-4), 0.0, 1.0);
}

#endif
