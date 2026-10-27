"""ios/Assets/puff.png: a soft radial-gradient smoke sprite for SCNParticleSystem (64x64 RGBA, white, alpha falloff)."""
import os, sys
import numpy as np
from PIL import Image

dst = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'Assets/puff.png')
n = 64; y, x = np.mgrid[0:n, 0:n]; r = np.hypot(x - (n - 1) / 2, y - (n - 1) / 2) / (n / 2)
alpha = np.clip(1 - r, 0, 1) ** 2.2                      # soft edge, no hard rim
img = np.zeros((n, n, 4), np.uint8); img[..., :3] = 255; img[..., 3] = (alpha * 255).astype(np.uint8)
Image.fromarray(img, 'RGBA').save(dst)
print(dst, os.path.getsize(dst), 'bytes')
