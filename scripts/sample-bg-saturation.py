#!/usr/bin/env python3
"""对一张 PNG 截图做网格取点采样,统计各点的 HSV 饱和度分布。

用途:跟 bakebg-repro.swift 配对使用,量化对比"我们烘出来的背景"跟"Apple Music
真机播放中窗口截图"的饱和度差异。背景/来龙去脉见
docs/features/07-lyrics-window.md 的"专项:背景取色逼近 Apple Music"一节。

**关键教训**(2026-08-23 踩过一次,详情见上面那节文档):
Core Image 的 CIAreaAverage(单一混合数值)不等价于对渲染结果做网格逐点采样——
两块色相差异很大的区域做面积平均会互相抵消/稀释饱和度读数,让"平均值"看起来比
人眼实际感知到的任何一块区域都低。校准 satTarget 这类常数必须用本脚本这种网格
采样的 p75/中位数,不能只看 bakebg-repro.swift 打印的 FINAL(area-average) 那行。

不依赖 PIL/numpy(本机通常没装),纯标准库手写 PNG 解码(仅支持非隔行、
8-bit/channel、RGB 或 RGBA 的 PNG——sips/screencapture/NSBitmapImageRep 默认导出的
格式都满足)。

用法:
  python3 scripts/sample-bg-saturation.py <image.png> [--grid COLSxROWS] \
      [--x0 FRAC] [--x1 FRAC] [--y0 FRAC] [--y1 FRAC]

默认网格是图像宽高的 [0.15, 0.9] 区间内 5x5 个点(适合 bakebg-repro.swift 输出的
360x360 baked_*.png;对真实 Apple Music 截图,通常需要用 --x0/--x1/--y0/--y1 先
截出"背景可见、不被封面/文字遮挡"的那一小片区域,再在里面取网格——具体截图的
UI 版式每次不同,没有一劳永逸的坐标)。
"""

import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    pos = 8
    width = height = bit_depth = color_type = None
    idat = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length
    if bit_depth != 8 or color_type not in (2, 6):
        raise ValueError(f"unsupported PNG: bit_depth={bit_depth} color_type={color_type} (need 8-bit RGB/RGBA)")
    channels = 4 if color_type == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * channels
    rows = []
    prev = bytearray(stride)
    off = 0
    for _ in range(height):
        filt = raw[off]
        off += 1
        line = bytearray(raw[off : off + stride])
        off += stride

        def paeth(a, b, c):
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            if pa <= pb and pa <= pc:
                return a
            if pb <= pc:
                return b
            return c

        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                line[i] = (line[i] + paeth(a, b, c)) & 0xFF
        rows.append(bytes(line))
        prev = line
    return width, height, channels, rows


def rgb_to_hsv(r, g, b):
    r, g, b = r / 255, g / 255, b / 255
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    if d == 0:
        h = 0.0
    elif mx == r:
        h = 60 * (((g - b) / d) % 6)
    elif mx == g:
        h = 60 * (((b - r) / d) + 2)
    else:
        h = 60 * (((r - g) / d) + 4)
    s = 0.0 if mx == 0 else d / mx
    return h, s, mx


def pixel(rows, channels, x, y):
    o = x * channels
    row = rows[y]
    return row[o], row[o + 1], row[o + 2]


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    path = args[0]
    cols = rows_n = 5
    x0, x1, y0, y1 = 0.15, 0.9, 0.15, 0.9
    i = 1
    while i < len(args):
        if args[i] == "--grid":
            cols, rows_n = map(int, args[i + 1].split("x"))
            i += 2
        elif args[i] == "--x0":
            x0 = float(args[i + 1]); i += 2
        elif args[i] == "--x1":
            x1 = float(args[i + 1]); i += 2
        elif args[i] == "--y0":
            y0 = float(args[i + 1]); i += 2
        elif args[i] == "--y1":
            y1 = float(args[i + 1]); i += 2
        else:
            i += 1

    width, height, channels, rowdata = read_png(path)
    sats = []
    print(f"{path}  ({width}x{height})")
    for gy in range(rows_n):
        fy = y0 + (y1 - y0) * gy / max(1, rows_n - 1)
        y = min(height - 1, int(fy * height))
        line = []
        for gx in range(cols):
            fx = x0 + (x1 - x0) * gx / max(1, cols - 1)
            x = min(width - 1, int(fx * width))
            r, g, b = pixel(rowdata, channels, x, y)
            h, s, v = rgb_to_hsv(r, g, b)
            sats.append(s)
            line.append(f"h={h:5.0f} s={s:.2f}")
        print("  " + "  ".join(line))

    sats.sort()
    n = len(sats)
    median = sats[n // 2]
    p75 = sats[int(n * 0.75)]
    print(f"\nn={n}  min={sats[0]:.3f}  median={median:.3f}  p75={p75:.3f}  max={sats[-1]:.3f}")


if __name__ == "__main__":
    main()
