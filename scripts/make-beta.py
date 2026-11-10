#!/usr/bin/env python3
"""Make the test version of the app: beta/index.html, served at /groupgraphs/beta/.

Usage:  python3 scripts/make-beta.py path/to/new-index.html
        (with no argument it copies the live index.html, so beta matches live)

The test version uses the same database and sign-in as the live app, shows a
"Test version" strip, and has its own home-screen icon and name ("GG Beta", beta/manifest.webmanifest). Ship an update to everyone by copying beta/index.html over
index.html with:  python3 scripts/make-beta.py --promote
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
beta = root / "beta" / "index.html"

def strip_beta(s):
    s = s.replace('<script src="../config.js"></script>', '<script src="config.js"></script>')
    s = s.replace('<meta name="apple-mobile-web-app-title" content="GG Beta">', '<meta name="apple-mobile-web-app-title" content="GroupGraphs">')
    s = s.replace('<meta name="theme-color" content="#e34948">', '<meta name="theme-color" content="#2348b8">')
    s = s.replace('src="../apple-touch-icon.png"', 'src="apple-touch-icon.png"').replace('navigator.serviceWorker.register("../sw.js")', 'navigator.serviceWorker.register("sw.js")')
    s = re.sub(r'\n<div class="betabadge".*?</div>', '', s, flags=re.S)
    s = s.replace('<title>GroupGraphs (test)</title>', '<title>GroupGraphs</title>')
    return s

if sys.argv[1:] == ["--promote"]:
    (root / "index.html").write_text(strip_beta(beta.read_text()))
    print("index.html now matches beta/index.html")
    sys.exit(0)

src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "index.html"
s = strip_beta(src.read_text())
for a, b in [('<script src="config.js"></script>', '<script src="../config.js"></script>'),
             ('<meta name="apple-mobile-web-app-title" content="GroupGraphs">', '<meta name="apple-mobile-web-app-title" content="GG Beta">'),
             ('<meta name="theme-color" content="#2348b8">', '<meta name="theme-color" content="#e34948">'),
             ('src="apple-touch-icon.png"', 'src="../apple-touch-icon.png"'),
             ('navigator.serviceWorker.register("sw.js")', 'navigator.serviceWorker.register("../sw.js")'),
             ('<title>GroupGraphs</title>', '<title>GroupGraphs (test)</title>')]:
    assert a in s, "missing: " + a
    s = s.replace(a, b)
badge = ('<div class="betabadge" style="background:#e34948;color:#fff;font:700 11px/1.2 system-ui,sans-serif;letter-spacing:.06em;'
         'text-transform:uppercase;text-align:center;padding:calc(6px + env(safe-area-inset-top, 0px)) 12px 6px">'
         'Test version · <a href="../" style="color:#fff">open the live app</a></div>')
s = s.replace('<body>', '<body>\n' + badge, 1)
assert 'betabadge' in s, "no <body> tag found"
beta.parent.mkdir(exist_ok=True)
beta.write_text(s)
print("wrote", beta.relative_to(root))
