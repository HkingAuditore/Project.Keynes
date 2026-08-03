import struct
import sys
import io
import numpy as np

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

PKSV = r'C:\Users\hkinghuang\AppData\Roaming\Godot\app_userdata\ProjectKeynes\saves\manual_1.pksv'
data = open(PKSV, 'rb').read()

# Godot4 var_to_bytes: String variant = 04 00 00 00 + len(4) + utf8 bytes(+pad to 4)
# PackedFloat32Array variant = 20 00 00 00 + len(4) + f32*len
def find_f32_array(blob, key):
    kb = key.encode('utf-8')
    i = blob.find(kb)
    results = []
    while i >= 0:
        # 字符串结束后 4 字节对齐
        j = i + len(kb)
        j = (j + 3) & ~3
        if j + 8 <= len(blob):
            vtype, n = struct.unpack_from('<II', blob, j)
            if vtype == 0x20 and 0 < n < 10_000_000 and j + 8 + 4 * n <= len(blob):
                arr = np.frombuffer(blob, dtype='<f4', count=n, offset=j + 8)
                results.append((i, arr.copy()))
        i = blob.find(kb, i + 1)
    return results

W, H = 100, 64
N = W * H

for key in ('cell_pos_x', 'cell_pos_y', 'cell_lat_norm', 'cell_slp'):
    hits = find_f32_array(data, key)
    for off, arr in hits:
        if arr.size != N:
            print('%s @%d: n=%d (skip, not cell-count)' % (key, off, arr.size))
            continue
        g = arr.reshape(H, W)
        print('%s @%d: n=%d min=%.4f max=%.4f' % (key, off, arr.size, arr.min(), arr.max()))
        # 与现码期望值对比
        row, col = np.mgrid[0:H, 0:W]
        if key == 'cell_pos_x':
            # 期望: sqrt(3)*hex*(col+0.5*(row&1)) — hex 未知, 用线性拟合估计有效 hex
            exp_unit = np.sqrt(3.0) * (col + 0.5 * (row & 1))
            est_hex = (g / np.maximum(exp_unit, 1e-9))[exp_unit > 1.0]
            print('   est hex_size: median=%.4f p5=%.4f p95=%.4f' % (np.median(est_hex), np.percentile(est_hex, 5), np.percentile(est_hex, 95)))
            print('   row0 pos_x[0..3]=%s  row0 pos_x[96..99]=%s' % (g[0, :4], g[0, 96:]))
            print('   row1 pos_x[0..3]=%s  row63 pos_x[0..3]=%s' % (g[1, :4], g[63, :4]))
        elif key == 'cell_pos_y':
            exp_unit = 1.5 * row + 0.5
            est_hex = (g / np.maximum(exp_unit, 1e-9))[exp_unit > 1.0]
            print('   est hex_size: median=%.4f p5=%.4f p95=%.4f' % (np.median(est_hex), np.percentile(est_hex, 5), np.percentile(est_hex, 95)))
            print('   pos_y rows 0,1,32,63: %.4f %.4f %.4f %.4f' % (g[0, 0], g[1, 0], g[32, 0], g[63, 0]))
        elif key == 'cell_lat_norm':
            print('   lat_norm rows 0,16,32,48,63 (col0): %.4f %.4f %.4f %.4f %.4f' % (g[0, 0], g[16, 0], g[32, 0], g[48, 0], g[63, 0]))
            print('   lat_norm 同行内是否恒定: row32 std=%.5f' % g[32].std())
        elif key == 'cell_slp':
            K = g[:, 0] - g[:, -1]
            print('   存档烘焙 SLP: seam K mean=%.4f std=%.4f | rowmean N pole=%.4f equator=%.4f S pole=%.4f' % (
                K.mean(), K.std(), g[:8].mean(), g[24:40].mean(), g[56:].mean()))
            rm = g.mean(axis=1)
            py = (1.5 * np.arange(H) + 2.5) / 100.0
            ls = 1.0 - 2.0 * py
            base_lat = -0.16 * np.cos(np.abs(ls) * np.pi * 3.0)
            print('   corr(rowmean, base_lat)=%.3f' % np.corrcoef(rm, base_lat)[0, 1])
