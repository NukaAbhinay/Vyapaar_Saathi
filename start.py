#!/usr/bin/env python3
"""
Start Paytm Vyaapar Saathi in a real browser tab.

    python3 start.py          (Windows: py start.py)

Why this exists: browsers refuse the microphone to a page that is opened from a file path, from a
LAN address, or inside an embedded preview pane. The only place the mic is allowed is a real tab on
http://localhost. This script serves the folder there and opens that tab for you.
"""
import http.server
import os
import socketserver
import sys
import threading
import webbrowser

APP = "Paytm_Vyaapar_Saathi.html"
HERE = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def log_message(self, fmt, *args):
        pass  # keep the terminal clean during a demo


def main():
    os.chdir(HERE)
    if not os.path.exists(os.path.join(HERE, APP)):
        print("Cannot find %s next to this script." % APP)
        return 1

    port = 8000
    httpd = None
    for candidate in (8000, 8001, 8080, 8888, 9000):
        try:
            httpd = socketserver.TCPServer(("127.0.0.1", candidate), Handler)
            port = candidate
            break
        except OSError:
            continue
    if httpd is None:
        print("No free port found in 8000, 8001, 8080, 8888, 9000.")
        return 1

    url = "http://localhost:%d/%s" % (port, APP)
    print("\n  Paytm Vyaapar Saathi")
    print("  " + "-" * len(url))
    print("  Open this in your browser:  %s" % url)
    print("  The microphone works only on this address.")
    print("  Press Ctrl+C to stop.\n")

    threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
