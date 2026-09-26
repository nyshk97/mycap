#!/usr/bin/env python3
"""スクロールキャプチャの検証用 fixture を作る（--scroll-frames に渡す）。

縦長の「ページ」（白地に文字の塊と色付きの箱）から、固定ヘッダ付きの窓をずらしながら切り出して
<out>/frames/fNN.png に書く。途中に同じコマ・上へ戻すコマも混ぜる。つないだ結果の期待画像は <out>/expected.png。
乱数の種は固定なので、何度作っても同じもの（1600px の高さ）になる。

使い方: python3 scripts/make_scroll_fixture.py <out>
比較:   swift scripts/png_diff.swift <撮れた png> <out>/expected.png   # maxdiff=0 なら一致
"""
import os
import random
import struct
import sys
import zlib

W, H, HEADER, PAGE = 800, 600, 60, 4000
# 窓の位置。0 の重複（変化なし）、380・250（上へ戻す）を含む
OFFSETS = [0, 0, 90, 230, 400, 380, 250, 700, 1000]


def make_page():
    random.seed(3)
    page = [bytearray(b"\xff" * (W * 3)) for _ in range(PAGE)]
    y = 20
    while y < PAGE - 40:
        if random.random() < 0.12:
            h = random.randint(60, 140)
            c = [random.randint(60, 220) for _ in range(3)]
            x0, x1 = random.randint(20, 200), random.randint(400, 760)
            for yy in range(y, min(PAGE, y + h)):
                page[yy][x0 * 3:x1 * 3] = bytes(c) * (x1 - x0)
            y += h + 20
            continue
        x = 24
        for _ in range(random.randint(10, 70)):
            ww = random.randint(4, 14)
            if x + ww > W - 40:
                break
            g, hh = random.randint(0, 90), random.randint(9, 14)
            for yy in range(y, y + hh):
                page[yy][x * 3:(x + ww) * 3] = bytes((g, g, g)) * ww
            x += ww + random.randint(2, 8)
        y += random.randint(22, 30)
    return page


def write_png(rows, path):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", len(rows[0]) // 3, len(rows), 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def main():
    out = sys.argv[1]
    os.makedirs(os.path.join(out, "frames"), exist_ok=True)
    page = make_page()
    header = [bytearray(bytes((30, 40, 90)) * W) for _ in range(HEADER)]
    for i, o in enumerate(OFFSETS):
        write_png(header + page[o:o + H - HEADER], os.path.join(out, "frames", f"f{i:02d}.png"))
    write_png(header + page[0:max(OFFSETS) + H - HEADER], os.path.join(out, "expected.png"))
    print(f"frames={len(OFFSETS)} expected_height={max(OFFSETS) + H}")


if __name__ == "__main__":
    main()
