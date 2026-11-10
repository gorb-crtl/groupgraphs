#!/usr/bin/env python3
"""Make the test version of the app: beta/index.html, served at /groupgraphs/beta/.

Usage:  python3 scripts/make-beta.py path/to/new-index.html
        (with no argument it copies the live index.html, so beta matches live)

The test version uses the same database and sign-in as the live app, and shows a
"Test version" badge. Ship an update to everyone by copying beta/index.html over
index.html with:  python3 scripts/make-beta.py --promote
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
beta = root / "beta" / "index.html"

def strip_beta(s):
    s = s.replace('<script src="../config.js"></script>', '<script src="config.js"></script>')
    s = s.replace('href="../manifest.webmanifest"', 'href="manifest.webmanifest"').replace('href="../apple-touch-icon.png"', 'href="apple-touch-icon.png"')
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
             ('href="manifest.webmanifest"', 'href="../manifest.webmanifest"'),
             ('href="apple-touch-icon.png"', 'href="../apple-touch-icon.png"'),
             ('src="apple-touch-icon.png"', 'src="../apple-touch-icon.png"'),
             ('navigator.serviceWorker.register("sw.js")', 'navigator.serviceWorker.register("../sw.js")'),
             ('<title>GroupGraphs</title>', '<title>GroupGraphs (test)</title>')]:
    assert a in s, "missing: " + a
    s = s.replace(a, b)
badge = ('<div class="betabadge" style="position:fixed;left:50%;top:0;transform:translateX(-50%);z-index:95;background:#e34948;color:#fff;'
         'font:700 11px/1 system-ui,sans-serif;letter-spacing:.06em;text-transform:uppercase;padding:5px 10px;border-radius:0 0 8px 8px">'
         'Test version · <a href="../" style="color:#fff">open the live app</a></div>')
s = s.replace('<body>', '<body>\n' + badge, 1)
assert 'betabadge' in s, "no <body> tag found"
beta.parent.mkdir(exist_ok=True)
beta.write_text(s)
print("wrote", beta.relative_to(root))
