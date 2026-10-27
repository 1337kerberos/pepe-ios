"""Procedural backdrop textures for the PiP card (ios/Assets/bg_*.png, 1024x1024 RGB; floor_shadow.png + glow.png RGBA).
  lounge : dark warm room gradient, soft warm spot upper-left, cool rim glow upper-right, vignette
  office : cool blue-grey gradient, faint window-light rectangle, blurred desk silhouette (shapes only)
  neon   : near-black with a faint violet floor haze (the drifting green/purple blobs are glow.png sprites in PepeScene)
Run: python3 ios/tools/make_backgrounds.py        (PIL + numpy only)
"""
import os, sys
import numpy as np
from PIL import Image, ImageFilter, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'Assets')
N = 1024
yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / (N - 1)   # 0..1, y down


def save(name, rgb, alpha=None):
    rgb = np.clip(rgb, 0, 1)
    img = (rgb * 255).astype(np.uint8)
    if alpha is not None:
        a = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)[..., None]; img = np.concatenate([img, a], 2); Image.fromarray(img, 'RGBA').save(os.path.join(OUT, name))
    else: Image.fromarray(img, 'RGB').save(os.path.join(OUT, name))
    print(name, os.path.getsize(os.path.join(OUT, name)), 'bytes')


def vignette(strength=0.55, power=1.8):
    r = np.hypot(xx - 0.5, (yy - 0.5) * 1.1) / 0.72
    return 1 - strength * np.clip(r, 0, 1) ** power


def glow(cx, cy, rx, ry, power=2.0):
    d = np.hypot((xx - cx) / rx, (yy - cy) / ry)
    return np.clip(1 - d, 0, 1) ** power


# ---- lounge
top, bottom = np.array([0.20, 0.12, 0.09]), np.array([0.07, 0.045, 0.04])
base = top[None, None, :] * (1 - yy[..., None]) + bottom[None, None, :] * yy[..., None]
spot = glow(0.22, 0.12, 0.55, 0.5, 2.2)[..., None] * np.array([0.55, 0.36, 0.18])     # warm spot upper-left
rim = glow(0.88, 0.25, 0.35, 0.4, 2.0)[..., None] * np.array([0.10, 0.16, 0.26])      # cool rim glow upper-right
floor = np.clip((yy - 0.72) / 0.28, 0, 1)[..., None] * np.array([0.06, 0.035, 0.025])  # a slightly lighter floor band
save('bg_lounge.png', (base + spot + rim + floor) * vignette()[..., None])

# ---- office
top, bottom = np.array([0.40, 0.46, 0.55]), np.array([0.18, 0.21, 0.27])
base = top[None, None, :] * (1 - yy[..., None]) + bottom[None, None, :] * yy[..., None]
win = np.zeros((N, N), np.float32); win[int(0.14 * N):int(0.52 * N), int(0.58 * N):int(0.90 * N)] = 1
win[int(0.14 * N):int(0.52 * N), int(0.735 * N):int(0.755 * N)] = 0.3; win[int(0.325 * N):int(0.345 * N), int(0.58 * N):int(0.90 * N)] = 0.3   # mullions
win = np.asarray(Image.fromarray((win * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(14)), np.float32) / 255
window = win[..., None] * np.array([0.42, 0.46, 0.50])
desk = Image.new('L', (N, N), 0); d = ImageDraw.Draw(desk)
d.rectangle([0, int(0.80 * N), N, int(0.86 * N)], fill=120)                      # desk top
d.rectangle([int(0.06 * N), int(0.86 * N), int(0.10 * N), N], fill=90)            # legs
d.rectangle([int(0.90 * N), int(0.86 * N), int(0.94 * N), N], fill=90)
d.rectangle([int(0.12 * N), int(0.64 * N), int(0.34 * N), int(0.80 * N)], fill=70)  # monitor
d.rectangle([int(0.40 * N), int(0.70 * N), int(0.52 * N), int(0.80 * N)], fill=60)  # a mug/stack
desk = np.asarray(desk.filter(ImageFilter.GaussianBlur(10)), np.float32) / 255
save('bg_office.png', (base * (1 - 0.7 * desk[..., None]) + window) * vignette(0.4)[..., None])

# ---- neon
base = np.array([0.03, 0.02, 0.05])[None, None, :] * np.ones((N, N, 1))
haze = np.clip((yy - 0.6) / 0.4, 0, 1)[..., None] ** 1.5 * np.array([0.10, 0.04, 0.16])
save('bg_neon.png', base + haze)

# ---- floor contact shadow (RGBA: dark soft ellipse, transparent elsewhere) and a glow sprite for the neon blobs
d = np.hypot((xx - 0.5) / 0.28, (yy - 0.5) / 0.20)
save('floor_shadow.png', np.zeros((N, N, 3)), np.clip(1 - d, 0, 1) ** 1.6 * 0.75)
n = 256; gy, gx = np.mgrid[0:n, 0:n].astype(np.float32) / (n - 1); r = np.hypot(gx - 0.5, gy - 0.5) / 0.5
save('glow.png', np.ones((n, n, 3)), np.clip(1 - r, 0, 1) ** 2.5)
