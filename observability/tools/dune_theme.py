"""Dune look for the Grafana dashboards (meta#99).

Colours are the Awakening look ("Arrakis night") of the tabr-tau design tokens (MIT), with the
Fremen blue as the secondary accent. The heading typeface is Dune Rise (SIL OFL 1.1, unmodified,
embedded in the banner image; licence text next to the font file). The data series keep the
validated categorical palette in gen_dashboards.py; these colours are for the chrome only.
"""
import base64
from pathlib import Path

GROUND, PANEL, RAISED = "#0e0c0a", "#16130f", "#211c16"
HAIR, BRONZE, RULE = "#4a3b28", "#a88a52", "#94794a"
TEXT, DIM = "#ece2cf", "#ada08a"
SPICE, GOLD, SKY, FREMEN = "#f0912f", "#d9b873", "#86a9c4", "#7bb6ff"
OK, WARN, BAD = "#7fbf90", "#e8b64a", "#ec7058"

_FONT = Path(__file__).parent / "fonts" / "DuneRise.ttf"


def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def banner_svg(title, subtitle, w=1600, h=150):
    font = base64.b64encode(_FONT.read_bytes()).decode()
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" preserveAspectRatio="xMidYMid slice">
<defs>
<style>@font-face{{font-family:"Dune Rise";src:url(data:font/ttf;base64,{font}) format("truetype")}}
.t{{font-family:"Dune Rise","Segoe UI",system-ui,sans-serif}}
.s{{font-family:"Segoe UI",system-ui,sans-serif}}</style>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="{GROUND}"/><stop offset=".45" stop-color="#2a180e"/>
<stop offset=".78" stop-color="#8a431a"/><stop offset="1" stop-color="#d9782b"/></linearGradient>
<radialGradient id="sun" cx=".78" cy="1" r=".55"><stop offset="0" stop-color="{SPICE}" stop-opacity=".55"/>
<stop offset="1" stop-color="{SPICE}" stop-opacity="0"/></radialGradient>
<linearGradient id="fade" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{GROUND}" stop-opacity=".78"/>
<stop offset=".55" stop-color="{GROUND}" stop-opacity=".25"/><stop offset="1" stop-color="{GROUND}" stop-opacity="0"/></linearGradient>
</defs>
<rect width="{w}" height="{h}" fill="url(#sky)"/>
<rect width="{w}" height="{h}" fill="url(#sun)"/>
<circle cx="{w*.86:.0f}" cy="34" r="11" fill="{TEXT}" opacity=".85"/>
<circle cx="{w*.89:.0f}" cy="52" r="6" fill="{TEXT}" opacity=".6"/>
<path d="M0 112 C 180 84 330 126 520 104 S 860 78 1040 106 S 1380 90 1600 108 L1600 150 L0 150Z" fill="#5a2a12" opacity=".92"/>
<path d="M0 128 C 220 104 400 140 640 122 S 1010 100 1220 126 S 1480 116 1600 124 L1600 150 L0 150Z" fill="#2e170b"/>
<path d="M0 142 C 260 126 470 150 760 140 S 1190 128 1400 142 S 1540 140 1600 138 L1600 150 L0 150Z" fill="{GROUND}"/>
<rect width="{w}" height="{h}" fill="url(#fade)"/>
<rect y="{h-2}" width="{w}" height="2" fill="{BRONZE}"/>
<text class="t" x="46" y="76" font-size="46" letter-spacing="3" fill="{GOLD}">{_esc(title)}</text>
<text class="s" x="48" y="106" font-size="15" letter-spacing="3.2" fill="{TEXT}" opacity=".88">{_esc(subtitle.upper())}</text>
</svg>'''


def banner_panel(pid, title, subtitle, x=0, y=0, w=24, h=4):
    svg = banner_svg(title, subtitle)
    uri = "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()
    return {
        "id": pid, "type": "text", "title": "", "transparent": True,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "options": {"mode": "html", "code": {"language": "plaintext", "showLineNumbers": False, "showMiniMap": False},
                    "content": f'<img alt="{_esc(title)}: {_esc(subtitle)}" src="{uri}" style="width:100%;height:100%;display:block;box-sizing:border-box;border:1px solid {HAIR};border-radius:3px">'},
    }
