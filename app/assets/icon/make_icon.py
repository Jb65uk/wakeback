# Renders the WakeBack app icon (icon.png, icon_fg.png) with headless Chromium: pip install playwright; python make_icon.py
# icon_mono.png is icon_fg.png with every visible pixel white (Android 13+ themed icons).
import asyncio, sys
from playwright.async_api import async_playwright
# Foreground art in a 1024 box. Android adaptive icons show roughly the middle 66% (the "safe zone"),
# so the art sits inside ~ 170..854.
ART = '''
<defs>
  <linearGradient id="wake" gradientUnits="userSpaceOnUse" x1="235" y1="800" x2="690" y2="335">
    <stop offset="0" stop-color="#4DABF7" stop-opacity="0"/>
    <stop offset="0.35" stop-color="#4DABF7" stop-opacity="0.9"/>
    <stop offset="1" stop-color="#F2F8FF" stop-opacity="1"/>
  </linearGradient>
  <linearGradient id="glow" gradientUnits="userSpaceOnUse" x1="235" y1="800" x2="690" y2="335">
    <stop offset="0" stop-color="#4DABF7" stop-opacity="0"/>
    <stop offset="1" stop-color="#4DABF7" stop-opacity="0.30"/>
  </linearGradient>
</defs>
<path d="M235 800 C 360 660, 500 720, 560 560 S 610 390, 690 335" fill="none" stroke="url(#glow)" stroke-width="150" stroke-linecap="round"/>
<path d="M235 800 C 360 660, 500 720, 560 560 S 610 390, 690 335" fill="none" stroke="url(#wake)" stroke-width="66" stroke-linecap="round"/>
<g transform="translate(716 312) rotate(56) scale(14.5)">
  <path d="M0,-11 L7,9 L0,5 L-7,9 Z" fill="#FFC72C" stroke="#13293A" stroke-width="1.1" stroke-linejoin="round"/>
</g>
'''
def svg(bg, art=True, rounded=False):
    r = ' rx="180"' if rounded else ''
    b = f'<rect width="1024" height="1024"{r} fill="{bg}"/>' if bg else ''
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{b}{ART if art else ""}</svg>'
async def main():
    async with async_playwright() as p:
        br = await p.chromium.launch(); pg = await br.new_page(viewport={'width':1024,'height':1024})
        for name, s, transparent in [('icon.png', svg('#13293A'), False), ('icon_fg.png', svg(None), True), ('preview_round.png', svg('#13293A', rounded=True), True)]:
            await pg.set_content(f'<html><body style="margin:0;background:transparent">{s}</body></html>')
            await pg.screenshot(path=name, omit_background=transparent, clip={'x':0,'y':0,'width':1024,'height':1024})
        # preview sheet: how it looks as a round/squircle launcher icon at phone sizes, on light and dark wallpapers
        sheet = '<html><body style="margin:0;display:flex;gap:40px;padding:30px;background:linear-gradient(90deg,#e9eef3 50%,#1b1f24 50%);align-items:center">'
        for bgc in ['light','dark']:
            for size, shape in [(192,'50%'),(192,'28%'),(96,'50%'),(56,'50%')]:
                small = svg('#13293A').replace('width="1024" height="1024"', 'width="%d" height="%d"' % (size, size), 1)
                col = '#333' if bgc == 'light' else '#ddd'
                sheet += ('<div style="text-align:center;font:14px system-ui;color:%s"><div style="width:%dpx;height:%dpx;border-radius:%s;'
                          'overflow:hidden;box-shadow:0 4px 14px rgba(0,0,0,.35)">%s</div><div style="margin-top:8px">WakeBack</div></div>') % (col, size, size, shape, small)
        sheet += '</body></html>'
        await pg.set_viewport_size({'width':1500,'height':300}); await pg.set_content(sheet); await pg.screenshot(path='icon_sheet.png')
        await br.close()
asyncio.run(main())
