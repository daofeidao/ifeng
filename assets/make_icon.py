#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
【风扇控制 / iFeng】图标生成器（纯 Python，无第三方依赖）

输出 1024x1024 的 PNG：圆角方形渐变底 + 四叶白色风扇 + 中心轴。
用 2x2 超采样做抗锯齿，构建时由 build.sh 调 sips/iconutil 转 .icns。

    python3 assets/make_icon.py assets/icon-1024.png
"""
import math
import struct
import sys
import zlib

SIZE = 1024
SS = 2                       # 每像素 2x2 子采样
TOP = (14, 99, 233)          # 渐变上色 #0E63E9
BOTTOM = (15, 184, 201)      # 渐变下色 #0FB8C9
WHITE = (255, 255, 255)


def norm(v):
    return v / SIZE * 2.0 - 1.0


def smoothstep(edge0, edge1, x):
    if edge1 == edge0:
        return 0.0 if x < edge0 else 1.0
    t = (x - edge0) / (edge1 - edge0)
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t)


def wrap_pi(a):
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


def superellipse(x, y, radius=0.965, power=4.2):
    """返回 0..1 的覆盖率（1 = 完全在形状内）"""
    ax = abs(x) / radius
    ay = abs(y) / radius
    if ax < 1e-9 and ay < 1e-9:
        return 1.0
    f = (ax ** power + ay ** power) ** (1.0 / power)
    # 以像素宽做软边
    edge = 1.0
    soft = 0.012
    return smoothstep(edge + soft, edge - soft, f)


def blade_coverage(x, y, r, theta):
    """四叶风扇：叶片随半径前倾，越靠外越宽，末端收圆"""
    R0, R1 = 0.17, 0.79
    if r < R0 or r > R1:
        return 0.0
    t = (r - R0) / (R1 - R0)
    swirl = 0.62 * t
    halfw = 0.085 + 0.36 * t
    for k in range(4):
        base = k * math.pi / 2.0
        d = wrap_pi(theta - base - swirl)
        if abs(d) < halfw:
            # 根部与末端的软过渡
            root = smoothstep(R0, R0 + 0.018, r)
            tip = smoothstep(R1, R1 - 0.030, r)
            side = smoothstep(halfw, halfw - 0.022, abs(d))
            return root * tip * side
    return 0.0


def render():
    rows = []
    inv = 1.0 / SS
    total = SS * SS
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            acc_bg = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    x = norm(px + (sx + 0.5) * inv)
                    y = norm(py + (sy + 0.5) * inv)

                    # 底色渐变
                    gt = (y + 1.0) * 0.5
                    col = mix(TOP, BOTTOM, gt)

                    # 左上角柔光
                    gx, gy = x + 0.34, y + 0.42
                    glow = max(0.0, 1.0 - math.hypot(gx, gy) / 1.05)
                    col = mix(col, WHITE, 0.13 * glow * glow)

                    r = math.hypot(x, y)
                    theta = math.atan2(y, x)

                    # 风扇叶片
                    bc = blade_coverage(x, y, r, theta)
                    if bc > 0:
                        col = mix(col, WHITE, 0.97 * bc)

                    # 中心轴
                    hub = smoothstep(0.175, 0.155, r)
                    if hub > 0:
                        col = mix(col, WHITE, hub)
                    inner = smoothstep(0.085, 0.070, r)
                    if inner > 0:
                        col = mix(col, mix(TOP, WHITE, 0.25), inner)

                    a = superellipse(x, y)
                    acc_bg[0] += col[0] * a
                    acc_bg[1] += col[1] * a
                    acc_bg[2] += col[2] * a
                    acc_bg[3] += a
            n = float(total)
            alpha = acc_bg[3] / n
            if alpha <= 0.0001:
                row += bytes((0, 0, 0, 0))
            else:
                row += bytes((
                    int(round(acc_bg[0] / n / alpha)),
                    int(round(acc_bg[1] / n / alpha)),
                    int(round(acc_bg[2] / n / alpha)),
                    int(round(alpha * 255)),
                ))
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png"
    write_png(out, render())
    print("written:", out)
