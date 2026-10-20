"""Build the annual-report paper tear mask from a generated deckle-edge sheet.

Why a bitmap instead of the shader-side procedural tear: the procedural wobble was
rejected as ugly. One authoritative silhouette now lives in this PNG and is consumed
by three places -- the paper field shader (alpha + edge shading), the sheet shadow
shader (outer falloff) and the running-head/footer veil (alpha).

Channel packing. RGB here is DATA, not colour: never resample, re-compress or run
"fix alpha border" over this file, or the distance fields collapse and the drop shadow
turns into a hard-edged rectangle.
  A  hard silhouette coverage, ~1px anti-aliased
  R  Euclidean distance from the tear contour INTO the paper,   d / NEAR_PX
  G  Euclidean distance from the tear contour OUTSIDE the paper, d / FAR_PX
  B  reserved (255 = no modulation)

Why distance fields and not a blur: the paper needs two narrow edge bands (1.4px and
7px) while the drop shadow needs a ~47px falloff. One blurred channel cannot span that
-- a sigma that keeps the shadow alive has already saturated the edge bands -- and a
blurred distance is an erf curve, which fed into pow() gives the wrong profile. A
distance transform is linear: d = channel * range, in pixels, exactly.

Source image (NOT committed, 1-3 MB). ImageGen parameters:
  size=1024x1536  quality=high  background=opaque
  prompt= see PROMPT below. background="transparent" is useless: the model paints the
  transparency checkerboard as real pixels, and its luminance (~223-238) collides with
  the ivory paper (~246), so keying becomes fragile. Pure black opaque is the only
  reliable background.

Run from the Godot project root:
  py -3.13 tools/ui/build_paper_tear_mask.py --audit <source.png>
  py -3.13 tools/ui/build_paper_tear_mask.py --source <source.png> [--preview <out.png>]
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage, stats

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/ui/annual_chronicle/paper_tear_mask.png"

NEAR_PX = 12.0  # R channel range: paper-side edge shading band
FAR_PX = 64.0  # G channel range: shadow falloff reach, must stay >= shadow_spread + 8
SUPERSAMPLE = 4  # silhouette is rasterised at 4x then box-filtered -> ~1px AA
VERTICAL_BAND = 0.62  # middle fraction of source rows kept; corners are discarded
VERTICAL_TRIM = 0.06  # drop this fraction of rows at each end of the valid span

BITE_MAX = 10.0  # deeper nicks are clipped, matches the "restrained" budget
PROTRUDE_MAX = 5.0  # outward fibres saturate smoothly at this depth
BG_RING = 8

PROMPT = """A single sheet of ivory-white handmade cotton rag paper, photographed straight
down (orthographic flatbed scan), the sheet centered and filling about 78% of the frame,
with at least 10% empty margin on all four sides. All four edges are hand-torn deckle: an
irregular fibrous fringe about 0.5% of the sheet width, with three or four visible nicks
about 1% of the sheet width deep and fine fiber fuzz between them. No cut edges, no ruled
lines, no scalloped or lacy pattern. The paper surface is blank and unprinted. BACKGROUND:
solid uniform pure black RGB 0,0,0, completely flat, absolutely no checkerboard, no
transparency grid, no grey squares. Pure even diffuse light from directly above: no cast
shadow, no drop shadow, no ambient occlusion, no lighting gradient, no vignette.
Orthographic top-down, no perspective, no lens distortion, ultra sharp focus."""


# ── geometry contract, mirrors annual_report_tokens.gd ──────────────────────────────
# Keep these three in lockstep with the GDScript or the UV mapping drifts.


def paper_width(viewport_w: float) -> float:
    measure = min(max(viewport_w * 0.36, 300.0), 660.0)
    padding = min(max(measure * 0.145, 26.0), 96.0)
    return min(measure + padding * 2.0, 880.0)


def tear_pad(viewport_w: float) -> float:
    return min(max(paper_width(viewport_w) * 0.030, 14.0), 32.0)


def shadow_spread(viewport_w: float) -> float:
    return max(10.0, paper_width(viewport_w) * 0.055)


def texture_size(viewport_w: float, viewport_h: float) -> tuple:
    """mask_rect at the reference viewport: paper + tear_pad + shadow_spread each side."""
    margin = tear_pad(viewport_w) + shadow_spread(viewport_w)
    width = int(round(paper_width(viewport_w) + margin * 2.0))
    return width, int(round(viewport_h)), margin


# ── keying ──────────────────────────────────────────────────────────────────────────


def _luminance(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def _ring(rgb: np.ndarray, width: int) -> np.ndarray:
    mask = np.ones(rgb.shape[:2], bool)
    mask[width:-width, width:-width] = False
    return rgb[mask]


def _to_linear(lum: np.ndarray) -> np.ndarray:
    return np.where(lum <= 0.04045, lum / 12.92, ((lum + 0.055) / 1.055) ** 2.4)


def key_foreground(rgb: np.ndarray, alpha: np.ndarray | None,
                   report: list | None = None) -> tuple:
    """Return (hard silhouette, soft paper coverage).

    On a black background the coverage can be inverted from luminance directly, which
    recovers the fine fibre fringe that a hard threshold plus a 3x3 opening destroys.
    That fringe is the whole point of the bitmap, so the dark path avoids any morphology
    beyond picking the largest component and filling holes. The soft coverage is also
    what row_edges() interpolates against to get sub-pixel edges.
    """
    lum = _luminance(rgb)
    foreground = None

    if alpha is not None and alpha.min() < 0.98:
        soft = np.clip(alpha, 0.0, 1.0)
        if report is not None:
            report.append("source alpha")
    else:
        ring = _ring(rgb, BG_RING)
        background_lum = float(_luminance(ring).mean())
        if background_lum < 0.12:
            # Linear-light coverage against a black backdrop, 50% -> the true silhouette.
            lin = _to_linear(lum)
            soft = np.clip(lin / max(float(np.percentile(lin, 90)), 1e-6), 0.0, 1.0)
            if report is not None:
                report.append(f"linear coverage key (bg {background_lum:.3f})")
        else:
            background = np.median(ring, axis=0)
            distance = np.linalg.norm(rgb - background[None, None, :], axis=2)
            soft = np.clip((lum - background_lum) / max(
                float(np.percentile(lum, 90)) - background_lum, 1e-6), 0.0, 1.0)
            foreground = (distance > 0.18) & (lum > 0.35)
            foreground = ndimage.binary_opening(foreground, structure=np.ones((3, 3)))
            foreground = ndimage.binary_closing(foreground, structure=np.ones((5, 5)))
            if report is not None:
                report.append(f"chroma distance key (bg {background_lum:.3f})")

    if foreground is None:
        foreground = soft > 0.5
    labels, count = ndimage.label(foreground)
    if count == 0:
        raise SystemExit("keying produced an empty foreground")
    sizes = ndimage.sum(foreground, labels, range(1, count + 1))
    foreground = labels == (int(np.argmax(sizes)) + 1)
    return ndimage.binary_fill_holes(foreground), soft


# ── profile ────────────────────────────────────────────────────────────────────────


def row_edges(soft: np.ndarray, foreground: np.ndarray) -> tuple:
    """Sub-pixel left/right silhouette per row, in pixel-edge coordinates.

    Snapping to the integer column of the first solid pixel throws away the whole fibre
    fringe and leaves plateaus dozens of rows long -- which reads as a machine cut, not
    a tear. Interpolating where the soft coverage crosses 0.5 recovers ~0.1px precision
    from the same image, for free.
    """
    height, width = foreground.shape
    left = np.full(height, np.nan)
    right = np.full(height, np.nan)
    for y in range(height):
        columns = np.nonzero(foreground[y])[0]
        if columns.size < 8:
            continue
        outer = int(columns[0])
        inner = int(columns[-1])
        above = soft[y, outer]
        below = soft[y, outer - 1] if outer > 0 else 0.0
        left[y] = (outer - 1) + (0.5 - below) / max(above - below, 1e-3) if outer > 0 else 0.0
        below_r = soft[y, inner]
        above_r = soft[y, inner + 1] if inner + 1 < width else 0.0
        right[y] = inner + (below_r - 0.5) / max(below_r - above_r, 1e-3) if inner + 1 < width else width
    return left, right


def valid_band(left: np.ndarray, right: np.ndarray) -> tuple:
    rows = np.nonzero(~np.isnan(left) & ~np.isnan(right))[0]
    if rows.size < 64:
        raise SystemExit("foreground has too few complete rows")
    top, bottom = rows[0], rows[-1]
    span = bottom - top
    top += int(span * VERTICAL_TRIM)
    bottom -= int(span * VERTICAL_TRIM)
    return top, bottom


def periodic_resample(profile: np.ndarray, height: int) -> np.ndarray:
    """Fill the texture height without clamping, which would leave a straight run."""
    k = max(16, profile.size // 12)
    weight = np.linspace(0.0, 1.0, k)
    blended = profile.copy()
    blended[-k:] = profile[-k:] * (1.0 - weight) + profile[:k] * weight
    source = np.arange(blended.size)
    target = np.arange(height) * blended.size / height
    return np.interp(target, source, blended, period=blended.size)


# ── audit ──────────────────────────────────────────────────────────────────────────


def audit(rgb: np.ndarray, foreground: np.ndarray, soft: np.ndarray,
          reference_width: float = 851.4) -> bool:
    height, width = foreground.shape
    left, right = row_edges(soft, foreground)
    top, bottom = valid_band(left, right)
    band_l = left[top:bottom + 1]
    band_r = right[top:bottom + 1]
    widths = band_r - band_l
    ok = True

    print("\n=== gates ===")

    def gate(label: str, passed: bool, detail: str) -> None:
        nonlocal ok
        ok = ok and passed
        print(f"  [{'PASS' if passed else 'FAIL'}] {label:<26} {detail}")

    # 1. no foreground touching the frame
    edge = int(min(height, width) * 0.03)
    touches = (
        foreground[:edge].any()
        or foreground[-edge:].any()
        or foreground[:, :edge].any()
        or foreground[:, -edge:].any()
    )
    gate("foreground clear of frame", not touches, f"margin {edge}px")

    # 2. paper area share
    share = float(foreground.mean())
    gate("paper area share", 0.45 <= share <= 0.85, f"{share:.3f}")

    # 3. row width uniformity -> rejects perspective / trapezoid
    ratio = float(np.percentile(widths, 95) / max(np.percentile(widths, 5), 1e-6))
    gate("row width p95/p5", ratio <= 1.08, f"{ratio:.4f}")

    # 4. edge slope -> rejects a rotated sheet
    slope_l = abs(float(np.polyfit(np.arange(band_l.size), band_l, 1)[0]))
    slope_r = abs(float(np.polyfit(np.arange(band_r.size), band_r, 1)[0]))
    gate("edge slope", max(slope_l, slope_r) <= 0.02, f"{slope_l:.5f} / {slope_r:.5f} px/row")

    # 5-6. First difference. Measured in TEXTURE pixels, not source pixels: the whole
    # point of the gate is how rough the edge reads on screen, and the source is ~1.22x
    # smaller than the reference sheet. (Snapping to integer source columns also injects
    # ~0.4 of fake roughness, which is exactly what sub-pixel extraction removes.)
    scale = reference_width / max(float(np.median(band_r - band_l)), 1e-6)
    diffs = np.concatenate([np.diff(band_l), np.diff(band_r)])
    spread = float(diffs.std()) * scale
    kurt = float(stats.kurtosis(diffs, fisher=True))
    gate("first difference std", 0.6 <= spread <= 4.0,
         f"{spread:.3f} texture px/row (x{scale:.2f})")
    gate("first difference kurtosis", kurt >= 1.0, f"{kurt:.3f} (excess)")

    # 7. background must be keyable
    ring = _luminance(_ring(rgb, BG_RING))
    gate("background ring", ring.mean() <= 0.30 and ring.std() <= 0.05,
         f"mean {ring.mean():.3f} std {ring.std():.3f}")

    # 8. no contact shadow hugging the contour
    d_out = ndimage.distance_transform_edt(~foreground)
    halo = (d_out >= 4) & (d_out <= 14)
    bg_lum = float(ring.mean())
    halo_lum = float(_luminance(rgb)[halo].mean()) if halo.any() else bg_lum
    gate("no contact shadow", halo_lum <= bg_lum + 0.08,
         f"halo {halo_lum:.3f} vs bg {bg_lum:.3f}")

    print("\n=== geometry ===")
    print(f"  source          {width} x {height}")
    print(f"  paper columns   {np.median(left[~np.isnan(left)]):.1f} .. "
          f"{np.median(right[~np.isnan(right)]):.1f}  (median)")
    print(f"  row width       p5 {np.percentile(widths, 5):.1f}  "
          f"median {np.median(widths):.1f}  p95 {np.percentile(widths, 95):.1f}")
    print(f"  bite depth      median {np.abs(diffs).mean():.3f}  "
          f"p95 {np.percentile(np.abs(diffs), 95):.3f}")
    print(f"  band rows       {top} .. {bottom}  ({band_l.size} rows)")
    return ok


# ── build ──────────────────────────────────────────────────────────────────────────


def saturate_bite(values: np.ndarray) -> np.ndarray:
    """Compress the profile into the bite budget WITHOUT ever creating a flat plateau.

    A hard clip is wrong here: every row that exceeds the limit collapses to the same
    depth, and a few hundred of those in a row read on screen as a rectangular tab
    sticking out of the paper with two square shoulders. tanh saturates asymptotically
    and stays monotone, so the fibre shape survives, the depth stays bounded, and the
    left edge keeps its clearance to the texture border (needed for G to saturate).
    """
    negative = values < 0.0
    soft = -PROTRUDE_MAX * np.tanh(np.minimum(values, 0.0) / -PROTRUDE_MAX)
    return np.where(negative, soft, np.minimum(values, BITE_MAX))


def build(rgb: np.ndarray, foreground: np.ndarray, soft: np.ndarray, texture_w: int,
          texture_h: int, margin: float) -> np.ndarray:
    left, right = row_edges(soft, foreground)
    top, bottom = valid_band(left, right)
    band_l = left[top:bottom + 1]
    band_r = right[top:bottom + 1]

    # The nominal edge is the MEDIAN, not the outermost fibre: anchoring on the extremes
    # would shrink the whole sheet by one mean bite and shift the text column left.
    l0 = float(np.median(band_l))
    r0 = float(np.median(band_r))
    scale = (texture_w - 2.0 * margin) / max(r0 - l0, 1e-6)
    print(f"\n  scale {scale:.4f} px/px   paper {texture_w - 2 * margin:.1f}px wide")

    bite_l = periodic_resample((band_l - l0) * scale, texture_h)
    bite_r = periodic_resample((r0 - band_r) * scale, texture_h)
    clamped = int((bite_l > BITE_MAX).sum() + (bite_r > BITE_MAX).sum())
    # No median filter here: a size-3 one removes ~16% of the real row-to-row jitter,
    # and that jitter is the fibre detail the bitmap exists to preserve.
    bite_l = saturate_bite(bite_l)
    bite_r = saturate_bite(bite_r)

    left_edge = margin + bite_l
    right_edge = (texture_w - margin) - bite_r
    if left_edge.max() >= right_edge.min():
        raise SystemExit("tear profile inverted: left edge crossed the right edge")

    # 4x supersample then box filter -> coverage, i.e. free ~1px anti-aliasing. The
    # profile is interpolated to ss*rows as well, otherwise the per-row step between
    # adjacent rows stays a hard staircase and only the vertical edges get smoothed.
    ss = SUPERSAMPLE
    rows_hi = texture_h * ss
    row_positions = np.arange(rows_hi) / float(ss)
    left_hi = np.interp(row_positions, np.arange(texture_h), left_edge)
    right_hi = np.interp(row_positions, np.arange(texture_h), right_edge)
    columns = np.arange(texture_w * ss)[None, :]
    high = ((columns >= left_hi[:, None] * ss) & (columns < right_hi[:, None] * ss))
    coverage = high.reshape(texture_h, ss, texture_w, ss).mean(axis=(1, 3))

    solid = coverage > 0.5
    pad = int(FAR_PX + NEAR_PX)
    padded = np.pad(solid, ((pad, pad), (0, 0)), mode="edge")
    d_in = ndimage.distance_transform_edt(padded)[pad:-pad]
    d_out = ndimage.distance_transform_edt(~padded)[pad:-pad]

    rgba = np.empty((texture_h, texture_w, 4), np.uint8)
    rgba[..., 0] = np.clip(d_in / NEAR_PX * 255.0, 0, 255).astype(np.uint8)
    rgba[..., 1] = np.clip(d_out / FAR_PX * 255.0, 0, 255).astype(np.uint8)
    rgba[..., 2] = 255
    rgba[..., 3] = np.clip(coverage * 255.0, 0, 255).astype(np.uint8)

    print("\n=== output ===")
    print(f"  bite_left   median {np.median(bite_l):.2f}  p95 "
          f"{np.percentile(bite_l, 95):.2f}  max {bite_l.max():.2f}")
    print(f"  bite_right  median {np.median(bite_r):.2f}  p95 "
          f"{np.percentile(bite_r, 95):.2f}  max {bite_r.max():.2f}")
    print(f"  protrusion  min {min(bite_l.min(), bite_r.min()):.2f}  "
          f"(hard-clipped at {BITE_MAX:.0f}: {clamped} rows)")
    print(f"  asymmetry   {abs(np.median(bite_l) - np.median(bite_r)):.2f}px")
    print(f"  visible width {np.median(right_edge - left_edge):.2f}px "
          f"(want {texture_w - 2 * margin:.2f})")
    print(f"  edge clearance left {left_edge.min():.2f}  right "
          f"{texture_w - right_edge.max():.2f}  (needs >= {FAR_PX:.0f} for G to saturate)")

    # Longest run of near-constant edge: a visible straight segment is exactly what the
    # bitmap is meant to avoid, so keep it under 10% of the height.
    quantised = np.round(left_edge * 2.0).astype(int)
    longest = run = 1
    for index in range(1, quantised.size):
        run = run + 1 if quantised[index] == quantised[index - 1] else 1
        longest = max(longest, run)
    share = longest / float(texture_h)
    print(f"  longest flat run {longest} rows ({share * 100:.1f}%) "
          f"{'FAIL' if share > 0.10 else 'ok'}")

    print(f"\n  channels  A=coverage  R=d_in/{NEAR_PX:.0f}px  "
          f"G=d_out/{FAR_PX:.0f}px  B=255")
    return rgba


def preview(rgba: np.ndarray, path: Path) -> None:
    """Composite over the desk colour so a human can judge the silhouette."""
    alpha = rgba[..., 3:4].astype(np.float32) / 255.0
    paper_rgb = np.stack([np.full(rgba.shape[:2], 0.972),
                          np.full(rgba.shape[:2], 0.938),
                          np.full(rgba.shape[:2], 0.856)], axis=2)
    backing = np.stack([np.full(rgba.shape[:2], 0.129),
                        np.full(rgba.shape[:2], 0.108),
                        np.full(rgba.shape[:2], 0.086)], axis=2)
    composited = paper_rgb * alpha + backing * (1.0 - alpha)
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(composited, 0, 1) * 255).astype(np.uint8)).save(path)
    print(f"  preview -> {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="generated deckle-edge sheet")
    parser.add_argument("--audit", type=Path, help="only run the gates, write nothing")
    parser.add_argument("--viewport", default="1920x1080", help="reference viewport")
    parser.add_argument("--preview", type=Path, help="composite a preview PNG here")
    parser.add_argument("--out", type=Path, default=OUT, help="mask output path")
    args = parser.parse_args()

    source = args.audit or args.source
    if source is None:
        parser.error("one of --audit or --source is required")

    image = Image.open(source)
    rgb = np.asarray(image.convert("RGB")).astype(np.float32) / 255.0
    alpha = None
    if "A" in image.getbands():
        alpha = np.asarray(image.getchannel("A")).astype(np.float32) / 255.0
    report: list = []
    foreground, soft = key_foreground(rgb, alpha, report)

    width, height = args.viewport.lower().split("x")
    reference_width = paper_width(float(width))
    texture_w, texture_h, margin = texture_size(float(width), float(height))

    print(f"source {source}")
    print(f"key {', '.join(report)}")
    print(f"foreground {foreground.mean():.4f} of frame, mode {image.mode}")
    print(f"reference {args.viewport}  sheet {reference_width:.1f}px  "
          f"texture {texture_w}x{texture_h}  margin {margin:.1f}px")
    passed = audit(rgb, foreground, soft, reference_width)
    if args.audit:
        print(f"\n{'ALL GATES PASS' if passed else 'GATES FAILED -- pick another candidate'}")
        raise SystemExit(0 if passed else 1)

    rgba = build(rgb, foreground, soft, texture_w, texture_h, margin)
    if args.preview:
        preview(rgba, args.preview)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgba, "RGBA").save(args.out, optimize=True)
    with Image.open(args.out) as written:
        print(f"\n  wrote {args.out.relative_to(ROOT)} {written.size} {written.mode}")


if __name__ == "__main__":
    main()
