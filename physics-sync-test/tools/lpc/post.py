# Post-process the generator's walk.png exports for Shift Work:
# - keep only the 9 used columns (stand + 8 walk frames), 4 rows (up, left, down, right)
# - staff (cashier_*, player_*): stamp a 3x2 white name tag on the polo's chest
import sys, json, zipfile, io, os
from PIL import Image
outdir = sys.argv[1]
looks = json.load(open('looks.json'))
os.makedirs(outdir, exist_ok=True)
def is_polo(px):
    r, g, b, a = px
    return a > 200 and g > r + 25 and g > b + 25
for name in looks:
    walk = Image.open(io.BytesIO(zipfile.ZipFile(f'out/{name}.zip').read('standard/walk.png'))).convert('RGBA')
    sheet = walk.crop((0, 0, 9 * 64, 256))
    if name.startswith(('cashier', 'player')):
        px = sheet.load()
        for row in (1, 2, 3):
            for col in range(9):
                x0, y0 = col * 64, row * 64
                pts = [(x, y) for y in range(y0, y0 + 64) for x in range(x0, x0 + 64) if is_polo(px[x, y])]
                if not pts:
                    continue
                top = min(y for _, y in pts)
                xs = [x for x, y in pts if top + 7 <= y <= top + 9]
                if not xs:
                    continue
                if row == 2:   # facing camera: tag on the wearer's left chest (viewer's right)
                    tx = (min(xs) + max(xs)) // 2 + 3
                elif row == 1: # facing left: front edge is the low-x side
                    tx = min(xs) + 1
                else:          # facing right
                    tx = max(xs) - 3
                ty = top + 8
                for dx in range(3):
                    for dy in range(2):
                        if px[tx + dx, ty + dy][3] > 200:
                            px[tx + dx, ty + dy] = (245, 245, 240, 255)
    sheet.save(f'{outdir}/{name}.png')
print('ok')
