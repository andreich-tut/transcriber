import json
import sys
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        data = b'incomplete-model'
        self.send_response(503 if self.path == '/model-error' else 200)
        self.send_header('Content-Length', str(100_000 if self.path == '/slow-model' else len(data)))
        self.end_headers()
        if self.path == '/slow-model':
            try:
                for _ in range(100):
                    self.wfile.write(b'x' * 1000)
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError): pass
        else:
            try: self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        mime = BytesParser(policy=policy.default).parsebytes(
            ('Content-Type: ' + self.headers['Content-Type'] + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + body)
        fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True) for part in mime.iter_parts()}
        expected = {'model': b'nemotron-3.5', 'language': b'ru', 'response_format': b'json', 'file': b'fixture-audio-bytes'}
        authorization = None
        if self.path == '/configured/v1/audio/transcriptions':
            expected = {'model': b'whisper-1', 'response_format': b'verbose_json', 'file': b'fixture-audio-bytes'}
            authorization = 'Bearer fixture-test-key'
        status, payload = 200, {'text': 'Привет, мир.', 'language': 'ru', 'duration': 1.5, 'segments': [{'id': 0, 'start': 0.0, 'end': 1.5, 'text': 'Привет, мир.', 'avg_logprob': -0.12}]}
        if fields != expected or self.headers.get('Authorization') != authorization:
            status, payload = 422, {'error': 'Invalid multipart fields or file bytes'}
        elif self.path == '/http-error':
            status, payload = 503, {'error': 'Model unavailable'}
        elif self.path == '/invalid':
            payload = {'segments': []}
        elif self.path == '/text-only':
            payload = {'text': 'Привет, мир.'}
        elif self.path == '/slow':
            time.sleep(2)
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
