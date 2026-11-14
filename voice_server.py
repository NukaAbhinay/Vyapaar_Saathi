#!/usr/bin/env python3
"""
Galla / Paytm Vyaapar Saathi — voice + drafting proxy.

The page never holds a key. It talks to this process, and this process talks to Sarvam.

    export SARVAM_API_KEY=sk_...            # required for voice
    python3 voice_server.py                 # http://localhost:8787

Then in the HTML, set:

    window.APP_CONFIG = { proxy: "http://localhost:8787", stt: "saaras:v4", tts: "bulbul:v3" };

Endpoints
    GET  /health          → {"ok":true,"stt":true,"tts":true,"llm":false}
    POST /stt?lang=te-IN  → raw audio body (audio/webm) → {"transcript":"…"}
    POST /tts             → {"text","lang"} → {"audio":"<base64 wav>"}
    POST /draft           → {"kind","lang","template","facts"} → {"text":"…"}

Only the standard library is used. Nothing is logged to disk; audio is held in memory for the
duration of one request and discarded.
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SARVAM_KEY = os.environ.get("SARVAM_API_KEY", "").strip()
SARVAM_BASE = os.environ.get("SARVAM_BASE", "https://api.sarvam.ai")
LLM_KEY = os.environ.get("LLM_API_KEY", "").strip()
LLM_URL = os.environ.get("LLM_URL", "").strip()
PORT = int(os.environ.get("PORT", "8787"))
ALLOW_ORIGIN = os.environ.get("ALLOW_ORIGIN", "*")

DEFAULT_STT = os.environ.get("SARVAM_STT_MODEL", "saaras:v4")
DEFAULT_TTS = os.environ.get("SARVAM_TTS_MODEL", "bulbul:v3")
TTS_SPEAKER = os.environ.get("SARVAM_TTS_SPEAKER", "shubh")


def sarvam_post(path, body, content_type):
    req = urllib.request.Request(
        SARVAM_BASE + path,
        data=body,
        headers={"api-subscription-key": SARVAM_KEY, "Content-Type": content_type},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode("utf-8"))


def multipart(field, filename, ctype, payload):
    boundary = "----galla" + base64.urlsafe_b64encode(os.urandom(9)).decode().strip("=")
    body = b"".join([
        ("--%s\r\n" % boundary).encode(),
        ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n' % (field, filename)).encode(),
        ("Content-Type: %s\r\n\r\n" % ctype).encode(),
        payload,
        ("\r\n--%s--\r\n" % boundary).encode(),
    ])
    return body, "multipart/form-data; boundary=" + boundary


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the terminal quiet during a demo
        sys.stderr.write("· " + (fmt % args) + "\n")

    # ---------- helpers ----------
    def _send(self, code, payload, ctype="application/json"):
        raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Access-Control-Allow-Origin", ALLOW_ORIGIN)
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        if urlparse(self.path).path == "/health":
            self._send(200, {"ok": True, "stt": bool(SARVAM_KEY), "tts": bool(SARVAM_KEY),
                             "llm": bool(LLM_KEY and LLM_URL)})
        else:
            self._send(404, {"error": "not found"})

    # ---------- endpoints ----------
    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if url.path == "/stt":
            return self.handle_stt(body, parse_qs(url.query))
        if url.path == "/tts":
            return self.handle_tts(body)
        if url.path == "/draft":
            return self.handle_draft(body)
        self._send(404, {"error": "not found"})

    def handle_stt(self, audio, query):
        if not SARVAM_KEY:
            return self._send(503, {"error": "no SARVAM_API_KEY on the server"})
        if len(audio) < 800:
            return self._send(400, {"error": "audio too short"})
        lang = (query.get("lang") or ["te-IN"])[0]
        model = (query.get("model") or [DEFAULT_STT])[0]
        payload, ctype = multipart("file", "clip.webm", "audio/webm", audio)
        # Sarvam takes the model and language as form fields; append them to the same body
        extra = b"".join([
            ("--%s\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n%s\r\n" % (ctype.split("boundary=")[1], model)).encode(),
            ("--%s\r\nContent-Disposition: form-data; name=\"language_code\"\r\n\r\n%s\r\n" % (ctype.split("boundary=")[1], lang)).encode(),
        ])
        tail = ("--%s--\r\n" % ctype.split("boundary=")[1]).encode()
        payload = payload.replace(tail, extra + tail)
        try:
            out = sarvam_post("/speech-to-text", payload, ctype)
        except urllib.error.HTTPError as e:
            return self._send(e.code, {"error": "sarvam: " + e.read().decode("utf-8", "ignore")[:300]})
        except Exception as e:  # network, timeout
            return self._send(502, {"error": str(e)[:300]})
        text = out.get("transcript") or out.get("text") or ""
        return self._send(200, {"transcript": text})

    def handle_tts(self, body):
        if not SARVAM_KEY:
            return self._send(503, {"error": "no SARVAM_API_KEY on the server"})
        try:
            req = json.loads(body or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})
        text = (req.get("text") or "")[:2400]
        if not text:
            return self._send(400, {"error": "no text"})
        payload = json.dumps({
            "text": text,
            "target_language_code": req.get("lang") or "te-IN",
            "speaker": TTS_SPEAKER,
            "model": req.get("model") or DEFAULT_TTS,
        }).encode()
        try:
            out = sarvam_post("/text-to-speech", payload, "application/json")
        except urllib.error.HTTPError as e:
            return self._send(e.code, {"error": "sarvam: " + e.read().decode("utf-8", "ignore")[:300]})
        except Exception as e:
            return self._send(502, {"error": str(e)[:300]})
        audios = out.get("audios") or []
        if not audios:
            return self._send(502, {"error": "no audio in response"})
        return self._send(200, {"audio": audios[0]})

    def handle_draft(self, body):
        """Words only. The page verifies every figure against its own engine afterwards."""
        try:
            req = json.loads(body or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})
        if not (LLM_KEY and LLM_URL):
            return self._send(200, {"text": req.get("template", ""), "source": "template"})
        prompt = (
            "Rewrite this message for a kirana shop owner. Keep every number exactly as given, "
            "change no figure, add no new figure, keep it under 45 words, respectful tone, "
            "language: %s.\n\nMessage: %s" % (req.get("lang", "en"), req.get("template", ""))
        )
        payload = json.dumps({"messages": [{"role": "user", "content": prompt}]}).encode()
        try:
            rq = urllib.request.Request(LLM_URL, data=payload,
                                        headers={"Authorization": "Bearer " + LLM_KEY,
                                                 "Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(rq, timeout=20) as r:
                out = json.loads(r.read().decode())
            text = (out.get("choices", [{}])[0].get("message", {}) or {}).get("content") or req.get("template", "")
        except Exception:
            text = req.get("template", "")
        return self._send(200, {"text": text, "source": "model"})


if __name__ == "__main__":
    print("Galla voice proxy on http://localhost:%d" % PORT)
    print("  Sarvam key: %s" % ("set" if SARVAM_KEY else "MISSING — /stt and /tts will answer 503"))
    print("  LLM key   : %s" % ("set" if LLM_KEY else "not set — /draft returns the template"))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
