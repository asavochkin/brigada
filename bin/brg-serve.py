#!/usr/bin/env python3
# brg-serve — the optional server of the human's board (DESIGN §9.1, §4). Python >= 3.8,
# stdlib only. Started by `brg board` (bash is the parent, this is its child); nothing else
# runs it. It serves the board page and the snapshot of run/board/ over 127.0.0.1 (--bind: an
# IPv4 address of this machine or 0.0.0.0, for a trusted network only), and
# turns the buttons of the page into brg calls made on behalf of the human. It writes no
# brigade state itself: every action is a `brg …` call (say, task new --as human, …);
# its own files are run/board/token|port|ready.<pid> and temp files of the message texts.
import errno
import hmac
import http.server
import json
import os
import re
import secrets
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

MAX_BODY = 1 << 20
MAX_OUT = 4000
NAME_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}')
CHAN_RE = re.compile(r'lobby|T[0-9]{3,6}')
TASKJS_RE = re.compile(r'/run/board/(T[0-9]{3,6})\.js')
TMP_PREFIX = '.srv.tmp.'
WIN = sys.platform == 'win32'
# a decimal IPv4 literal without leading zeros (our own check: ipaddress of Python < 3.8.12 /
# 3.9.5 takes them; [0-9], not \d: \d matches other Unicode digits)
IPV4_RE = re.compile(r'(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}')
# EADDRNOTAVAIL (Windows: WSAEADDRNOTAVAIL): the address is not on this machine
ADDRNOTAVAIL = (errno.EADDRNOTAVAIL, 10049)

CFG = {}  # root, proj, bd, port, token, bash, interval, bind (the address the board is open at)


def is_ipv4(s):
    return bool(IPV4_RE.fullmatch(s)) and all(int(o) <= 255 for o in s.split('.'))


def is_loopback(host):
    # host without the port: 127.0.0.0/8 or localhost
    return host == 'localhost' or (is_ipv4(host) and host.startswith('127.'))


def say(text, err=False):
    # the terminal of `brg board`; flushed at once (a pipe is block-buffered)
    try:
        print(text, file=sys.stderr if err else sys.stdout, flush=True)
    except Exception:
        pass


def atomic_write(path, data, mode=None):
    tmp = os.path.join(os.path.dirname(path), TMP_PREFIX + os.path.basename(path) + '.' + str(os.getpid()))
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(tmp, flags, mode if mode is not None else 0o666)
    with os.fdopen(fd, 'wb') as f:
        f.write(data.encode('utf-8'))
    for i in range(10):
        try:
            os.replace(tmp, path)
            return
        except OSError:
            if i == 9:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
            time.sleep(0.1)


TOKEN_RE = re.compile(r'[0-9a-f]{32}')


def read_token(path):
    try:
        with open(path, 'r', encoding='ascii') as f:
            t = f.readline().strip()
        if TOKEN_RE.fullmatch(t):
            return t
    except (OSError, UnicodeDecodeError):
        pass
    return None


def load_token(bd):
    # The token is created once and never changed while it is valid. Two first starts at once
    # must agree on it: the full value goes to a temp file, which is published by os.link
    # (atomic, never overwrites); the loser reads the winner's complete file. Without hard
    # links (SMB, exFAT): O_EXCL, and the loser waits up to ~2 s for the winner to write it.
    path = os.path.join(bd, 'token')
    hook = (os.environ.get('BRG_SERVE_TEST_TOKEN') or '').split(',')  # test hook: nolink, stall, race
    t = read_token(path)
    if t:
        return t
    if 'race' in hook:
        time.sleep(0.5)  # test hook: two first starts both surely see "no token"
    t = secrets.token_hex(16)
    data = (t + '\n').encode('ascii')
    tmp = os.path.join(bd, TMP_PREFIX + 'token.' + str(os.getpid()))
    linked = False
    if 'nolink' not in hook:
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'wb') as f:
                f.write(data)
            try:
                os.link(tmp, path)
            except FileExistsError:
                pass
            linked = True
        except OSError:
            pass  # no hard links here: O_EXCL below
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    if not linked:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            fd = None
        if fd is not None:
            with os.fdopen(fd, 'wb') as f:
                if 'stall' in hook:
                    time.sleep(1.5)  # test hook: the winner stops between create and write
                f.write(data)
    for _ in range(20):
        r = read_token(path)
        if r:
            return r
        time.sleep(0.1)
    # still no valid token (a broken file, or its writer died before writing): replace it.
    # Two starts over a broken file both get here at about the same time (each waited 2 s)
    # and both replace it: after a pause each re-reads the file, so both take the last
    # write. A start more than 0.5 s behind could still keep its own — accepted (a broken
    # token file and two first starts at once).
    atomic_write(path, t + '\n', 0o600)
    time.sleep(0.5)
    return read_token(path) or t


def clean_tmp(bd):
    # leftovers of a killed server: temp files older than a minute
    now = time.time()
    try:
        names = os.listdir(bd)
    except OSError:
        return
    for n in names:
        p = os.path.join(bd, n)
        # temp files, heartbeats of killed boards, the shared ready file of an older brg
        if n.startswith(TMP_PREFIX) or n.startswith('alive.') or n == 'ready':
            try:
                if now - os.path.getmtime(p) > 60:
                    os.unlink(p)
            except OSError:
                pass
        elif n.startswith('ready.') and not os.path.exists(os.path.join(bd, 'alive.' + n[6:])):
            # the ready file of a killed server: its brg board writes no heartbeat any more
            try:
                os.unlink(p)
            except OSError:
                pass


# ── brg calls ──────────────────────────────────────────────────────────────
class Refuse(Exception):
    pass


def brg_cmd():
    root = CFG['root']
    if WIN:
        return [os.path.normpath(os.path.join(root, 'bin', 'brg.cmd'))]  # backslashes: cmd.exe takes / for a switch
    return [CFG['bash'], os.path.join(root, 'bin', 'brg')]


def run_brg(args):
    env = dict(os.environ)
    env.pop('BRG_AS', None)
    env['BRG_NO_CHCP'] = '1'  # brg.cmd would run chcp on the shared console
    env['MSYS'] = 'noglob'  # Git Bash started from python.exe would expand README* in the arguments
    try:
        p = subprocess.run(brg_cmd() + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, cwd=CFG['proj'], env=env, timeout=60)
        out, code = p.stdout.decode('utf-8', 'replace'), p.returncode
    except subprocess.TimeoutExpired:
        out, code = 'brg не ответил за 60 с', 124
    except OSError as e:
        out, code = 'не удалось запустить brg: %s' % e, 127
    out = out.replace('\r\n', '\n').strip()
    if len(out) > MAX_OUT:
        out = out[:MAX_OUT] + '…'
    return code, out


class TextFile:
    # the text of a message / brief goes to brg only through --file
    def __init__(self, text):
        if not isinstance(text, str) or not text.strip():
            raise Refuse('пустой текст')
        try:
            data = text.encode('utf-8')
        except UnicodeEncodeError:
            raise Refuse('текст не в UTF-8')
        if b'\0' in data:
            raise Refuse('в тексте нулевой байт')
        self.data = data
        self.path = None

    def __enter__(self):
        fd, path = tempfile.mkstemp(prefix=TMP_PREFIX, suffix='.txt', dir=CFG['bd'])
        with os.fdopen(fd, 'wb') as f:
            f.write(self.data)
        self.path = path.replace('\\', '/')
        return self.path

    def __exit__(self, *a):
        if self.path:
            try:
                os.unlink(self.path)
            except OSError:
                pass


def v_name(x, what='имя'):
    if not isinstance(x, str) or not NAME_RE.fullmatch(x):
        raise Refuse('недопустимое %s' % what)
    return x


def v_chan(x):
    if not isinstance(x, str) or not CHAN_RE.fullmatch(x):
        raise Refuse('недопустимый канал')
    return x


def v_title(x):
    if not isinstance(x, str):
        raise Refuse('нужен заголовок')
    x = x.strip()
    if not x:
        raise Refuse('нужен заголовок')
    if re.search(r'[\x00-\x1f\x7f  ]', x):
        raise Refuse('в заголовке управляющие символы (заголовок — одна строка)')
    try:
        n = len(x.encode('utf-8'))
    except UnicodeEncodeError:
        raise Refuse('заголовок не в UTF-8')
    if n > 200:
        raise Refuse('заголовок длиннее 200 байт (%d) — подробности пиши в постановке' % n)
    if WIN and re.search(r'["%^&|<>!]', x):
        raise Refuse('в заголовке нельзя " % ^ & | < > ! (Windows) — убери их, подробности пиши в постановке')
    return x


def opt_name(d):
    n = d.get('name')
    if n in (None, ''):
        return None
    return v_name(n)


def act_say(d):
    to = d.get('to', 'all')
    if isinstance(to, str):
        to = [to]
    if not isinstance(to, list) or not to or len(to) > 64:
        raise Refuse('недопустимое «кому»')
    for t in to:
        if t != 'all':
            v_name(t)
    if 'all' in to and len(to) > 1:
        raise Refuse('«всем» нельзя смешивать с именами')
    args = ['say', '--to', ','.join(to)]
    if d.get('channel') not in (None, ''):
        args += ['--channel', v_chan(d['channel'])]
    re_ = d.get('re')
    if re_ not in (None, ''):
        re_ = str(re_)
        if not re.fullmatch(r'[0-9]{1,9}', re_):
            raise Refuse('--re — номер сообщения')
        args += ['--re', re_]
    with TextFile(d.get('text')) as f:
        code, out = run_brg(args + ['--file', f])
    m = re.search(r'#(\d+)', out)
    note = 'say → %s%s%s' % (','.join(to), ' (#%s)' % m.group(1) if m and code == 0 else '', ' re #' + re_ if re_ else '')
    return code, out, note


def act_task_new(d):
    title = v_title(d.get('title'))
    args = ['task', 'new', '--as', 'human', '--title', title]
    if d.get('cancel_current'):
        args.append('--cancel-current')
    with TextFile(d.get('brief')) as f:
        code, out = run_brg(args + ['--file', f])
    return code, out, 'новая задача «%s»%s' % (title, ' (текущая отменена)' if d.get('cancel_current') else '')


def act_task_cancel(d):
    code, out = run_brg(['task', 'cancel', '--as', 'human'])
    return code, out, 'отмена задачи'


def act_lead(d):
    n = v_name(d.get('name'))
    code, out = run_brg(['lead', 'give', n, '--as', 'human'])
    return code, out, 'lead → %s' % n


def _simple(cmd):
    def act(d):
        n = opt_name(d)
        code, out = run_brg([cmd] + ([n] if n else []))
        return code, out, '%s%s' % (cmd, ' ' + n if n else ' всех')
    return act


MODEL_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/@#+-]{0,119}')
HARNESS_RE = re.compile(r'[a-z0-9]{1,20}')
SPAWN_RE = re.compile(r'S[0-9]{3,6}')


def act_spawn(d):
    # agents launched by brg (DESIGN §5.5): `brg spawn` returns at once (the supervisor is detached)
    h = d.get('harness')
    if not isinstance(h, str) or not HARNESS_RE.fullmatch(h):
        raise Refuse('недопустимый харнесс')
    m = d.get('model')
    if not isinstance(m, str) or not MODEL_RE.fullmatch(m):
        raise Refuse('недопустимая модель: буквы, цифры и ._:/@#+- (не с «-»), до 120 символов')
    r = d.get('rights', 'full')
    if r not in ('full', 'project'):
        raise Refuse('права — full или project')
    c = d.get('count', 1)
    if isinstance(c, str) and c.isdigit():
        c = int(c)
    if isinstance(c, bool) or not isinstance(c, int) or not 1 <= c <= 5:
        raise Refuse('число агентов — от 1 до 5')
    args = ['spawn', h, '--model', m, '--rights', r, '--count', str(c)]
    note = d.get('note')
    if note not in (None, ''):
        if not isinstance(note, str) or re.search(r'[\x00-\x1f\x7f  ]', note):
            raise Refuse('подпись — одна строка')
        try:
            n = len(note.encode('utf-8'))
        except UnicodeEncodeError:
            raise Refuse('подпись не в UTF-8')
        if n > 200:
            raise Refuse('подпись длиннее 200 байт (%d)' % n)
        args += ['--note', note]
    code, out = run_brg(args)
    return code, out, 'spawn %s × %d (%s, права %s)' % (h, c, m, r)


def act_spawn_ctl(d):
    i = d.get('id')
    if not isinstance(i, str) or not (SPAWN_RE.fullmatch(i) or NAME_RE.fullmatch(i)):
        raise Refuse('недопустимый запуск: S00N или имя агента')
    op = d.get('op')
    if op not in ('wake', 'rm', 'detach', 'rights'):
        raise Refuse('действие — wake, rm, detach или rights')
    args = ['spawn', op, i]
    if op == 'rights':
        r = d.get('rights')
        if r not in ('full', 'project'):
            raise Refuse('права — full или project')
        args.append(r)
    code, out = run_brg(args)
    return code, out, 'spawn %s %s%s' % (op, i, ' ' + args[-1] if op == 'rights' else '')


ACTIONS = {
    'spawn': act_spawn,
    'spawn-ctl': act_spawn_ctl,
    'say': act_say,
    'task-new': act_task_new,
    'task-cancel': act_task_cancel,
    'lead': act_lead,
    'pause': _simple('pause'),
    'resume': _simple('resume'),
    'stop': _simple('stop'),
}


# ── http ───────────────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'brg-serve'
    sys_version = ''
    timeout = 30

    def log_message(self, fmt, *args):  # the default one prints URLs (with ?t=<token>)
        pass

    # headers on every response
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "frame-ancestors 'none'")
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Content-Type-Options', 'nosniff')
        http.server.BaseHTTPRequestHandler.end_headers(self)

    def reply(self, code, body=b'', ctype='text/plain; charset=utf-8', extra=()):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def reply_json(self, code, obj):
        self.reply(code, json.dumps(obj, ensure_ascii=False), 'application/json; charset=utf-8')

    def method_not_allowed(self):
        self.reply(405, 'только GET и POST', extra=[('Allow', 'GET, POST')])

    do_OPTIONS = do_HEAD = do_PUT = do_DELETE = do_PATCH = method_not_allowed

    def __getattr__(self, name):
        # any other method (TRACE, CONNECT, …): 405 as well, not the stdlib's 501
        if name.startswith('do_'):
            return self.method_not_allowed
        raise AttributeError(name)

    def host_check(self):
        # None if the Host is ours, else why not. The port is ours always (a tunnel keeps the
        # same number on both sides). 127.0.0.1 and localhost are always fine (also through an SSH
        # tunnel); --bind IP adds IP; --bind 0.0.0.0 adds any IPv4 literal but not a name: a name in
        # Host is what a DNS-rebinding page has, and 0.0.0.0 is not an address to connect to.
        h = (self.headers.get('Host') or '').lower()
        p = CFG['port']
        name, sep, port = h.rpartition(':')
        if not sep or port != str(p):
            return 'Host не тот: порт в адресе должен быть %d (SSH-туннель — тот же номер порта с обеих сторон)' % p
        b = CFG['bind']
        if name in ('127.0.0.1', 'localhost') or (b != '0.0.0.0' and name == b) \
                or (b == '0.0.0.0' and name != '0.0.0.0' and is_ipv4(name)):
            return None
        return 'Host не тот: открой доску по адресу из вывода brg board (IP-адрес, не имя)'

    def remote(self):
        # the request came to an address that is not loopback: no Sec-Fetch-*, the snapshot needs k
        name = (self.headers.get('Host') or '').lower().rpartition(':')[0]
        return not is_loopback(name)

    def cookie_ok(self):
        name = 'brg_%d=' % CFG['port']
        for hdr in self.headers.get_all('Cookie') or []:
            for part in hdr.split(';'):
                part = part.strip()
                if part.startswith(name) and self.token_eq(part[len(name):]):
                    return True
        return False

    @staticmethod
    def token_eq(t):
        try:
            return hmac.compare_digest(t.encode('ascii'), CFG['token'].encode('ascii'))
        except (UnicodeEncodeError, AttributeError):
            return False

    def origin_ok(self):
        # same origin as the page: http:// + the Host of this very request (already checked)
        o = self.headers.get('Origin')
        if o is None:
            return True
        return o == 'http://' + (self.headers.get('Host') or '').lower()

    def do_GET(self):
        why = self.host_check()
        if why:
            return self.reply(403, why)
        u = urllib.parse.urlsplit(self.path)
        if u.path == '/' and 't' in urllib.parse.parse_qs(u.query):
            # the address from `brg board`: the token goes into a cookie and out of the address bar
            t = urllib.parse.parse_qs(u.query)['t'][0]
            if not self.token_eq(t):
                return self.reply(403, 'неверный токен — открой адрес из вывода brg board')
            return self.reply(303, '', extra=[
                ('Location', '/'),
                ('Set-Cookie', 'brg_%d=%s; HttpOnly; SameSite=Strict; Path=/' % (CFG['port'], CFG['token']))])
        if not self.cookie_ok():
            return self.reply(403, 'открой адрес из вывода brg board')
        if u.path == '/':
            return self.page()
        if u.path == '/run/board/data.js' or TASKJS_RE.fullmatch(u.path):
            # a script tag of a page from another port of this host is the same site for SameSite
            # and would carry the cookie: the snapshot is read only by our own page. Fetch Metadata
            # (Sec-Fetch-Site) is sent only to potentially trustworthy URLs (loopback, https), so
            # at any other address the page adds the token to the address of the script (k)
            if self.headers.get('Sec-Fetch-Site') not in (None, 'same-origin'):
                return self.reply(403, 'снимок читает только страница доски')
            k = urllib.parse.parse_qs(u.query, keep_blank_values=True).get('k')
            if k is None and self.remote():
                return self.reply(403, 'снимок читает только страница доски (нужен k)')
            if k is not None and not self.token_eq(k[0]):
                return self.reply(403, 'снимок читает только страница доски (k не тот)')
            return self.static(os.path.join(CFG['bd'], u.path.rsplit('/', 1)[1]), 'application/javascript; charset=utf-8')
        self.reply(404, 'нет такого пути')

    def static(self, path, ctype):
        try:
            with open(path, 'rb') as f:
                data = f.read()
        except OSError:
            return self.reply(404, 'нет файла')
        self.reply(200, data, ctype)

    def page(self):
        try:
            with open(os.path.join(CFG['root'], 'board.html'), 'r', encoding='utf-8') as f:
                html = f.read()
        except OSError:
            return self.reply(404, 'нет .brigada/board.html — обнови: brg init')
        meta = '<meta name="brg-token" content="%s">' % CFG['token']
        if '<!--BRG_META-->' in html:
            html = html.replace('<!--BRG_META-->', meta, 1)
        else:
            html = html.replace('</head>', meta + '</head>', 1)
        self.reply(200, html, 'text/html; charset=utf-8')

    def do_POST(self):
        # the body is read first, whatever the verdict: closing with unread data resets the
        # connection and the page would see a network error instead of the answer
        cl = self.headers.get('Content-Length')
        n = int(cl) if cl is not None and cl.isascii() and cl.isdigit() and not self.headers.get('Transfer-Encoding') else -1
        raw = self.rfile.read(n) if 0 <= n <= MAX_BODY else b''
        why = self.host_check()
        if why:
            return self.reply(403, why)
        if not self.cookie_ok() or not self.token_eq(self.headers.get('X-Brg-Token') or ''):
            return self.reply(403, 'нужны cookie и X-Brg-Token')
        if not self.origin_ok():
            return self.reply(403, 'Origin не тот')
        if self.headers.get('Transfer-Encoding') or n < 0:
            return self.reply(411, 'нужен Content-Length (chunked не поддерживается)')
        if n > MAX_BODY:
            return self.reply(413, 'тело больше 1 МБ')
        if (self.headers.get('Content-Type') or '').split(';')[0].strip().lower() != 'application/json':
            return self.reply(415, 'нужен Content-Type: application/json')
        m = re.fullmatch(r'/api/([a-z-]+)', self.path)
        fn = ACTIONS.get(m.group(1)) if m else None
        if fn is None:
            return self.reply(404, 'нет такого действия')
        try:
            d = json.loads(raw.decode('utf-8'))
            if not isinstance(d, dict):
                raise ValueError
        except (ValueError, UnicodeDecodeError):
            return self.reply_json(400, {'ok': False, 'code': -1, 'out': 'тело — не JSON-объект'})
        try:
            code, out, note = fn(d)
        except Refuse as e:
            return self.reply_json(400, {'ok': False, 'code': -1, 'out': str(e)})
        who = ' (с %s)' % self.client_address[0] if self.remote() else ''  # not from this machine
        say('── с доски: %s%s%s' % (note, who, '' if code == 0 else ' — ОШИБКА (код %d)' % code))
        self.reply_json(200, {'ok': code == 0, 'code': code, 'out': out})


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = not WIN  # on Windows SO_REUSEADDR lets a second process take the port

    def server_bind(self):
        # HTTPServer's own one asks DNS for the name of the address (getfqdn): a slow answer
        # would eat the 5 s of the handshake with brg
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


# ── main ───────────────────────────────────────────────────────────────────
def main(argv):
    opt = {'root': None, 'port': 0, 'retry': False, 'interval': 2, 'alive': 'alive', 'ready': 'ready',
           'bind': '127.0.0.1'}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--retry-any':
            opt['retry'] = True
            i += 1
        elif a == '--bind' and i + 1 < len(argv):
            if not is_ipv4(argv[i + 1]):
                say('brg-serve: --bind — IPv4-адрес вида 192.168.0.5 или 0.0.0.0', True)
                return 2
            opt['bind'] = argv[i + 1]
            i += 2
        elif a in ('--root', '--port', '--interval', '--alive', '--ready') and i + 1 < len(argv):
            try:
                opt[a[2:]] = argv[i + 1] if a in ('--root', '--alive', '--ready') else int(argv[i + 1])
            except ValueError:
                say('brg-serve: %s — число' % a, True)
                return 2
            i += 2
        else:
            say('brg-serve: неизвестный параметр %s' % a, True)
            return 2
    root = opt['root']
    if not root or not os.path.isdir(root):
        say('brg-serve: нужен --root <.brigada>', True)
        return 2
    bd = os.path.join(root, 'run', 'board')
    os.makedirs(bd, exist_ok=True)
    CFG.update(root=root, proj=os.path.dirname(root.rstrip('/\\')) or root, bd=bd,
               bash=os.environ.get('BRG_SERVE_BASH') or 'bash', interval=max(1, opt['interval']),
               bind=opt['bind'])
    clean_tmp(bd)
    # test hook: really listen on loopback while the rules (Host, Origin) follow --bind; it can
    # only narrow what is listened on, any other value is ignored
    listen = '127.0.0.1' if os.environ.get('BRG_SERVE_TEST_LISTEN') == '127.0.0.1' else opt['bind']
    # 0.0.0.0 without SO_REUSEADDR: on macOS it would bind over a busy 127.0.0.1:P of another process
    Server.allow_reuse_address = not WIN and opt['bind'] != '0.0.0.0'
    busy = 0  # the saved port was taken: ready tells brg, which says so after the address
    try:
        srv = Server((listen, opt['port']), Handler)
    except OSError as e:
        if e.errno in ADDRNOTAVAIL:  # before the retry: another port does not help
            say('── brg-serve: адрес %s не на этой машине: %s' % (opt['bind'], e), True)
            return 5
        if opt['port'] and opt['retry']:
            busy = opt['port']
            try:
                srv = Server((listen, 0), Handler)
            except OSError as e2:
                if e2.errno in ADDRNOTAVAIL:
                    say('── brg-serve: адрес %s не на этой машине: %s' % (opt['bind'], e2), True)
                    return 5
                say('── brg-serve: не удалось занять порт: %s' % e2, True)
                return 3
        else:
            say('── brg-serve: порт %d занят или недоступен: %s' % (opt['port'], e), True)
            return 3
    CFG['port'] = srv.server_address[1]
    CFG['token'] = load_token(bd)
    ppid0 = os.getppid()
    started = time.time()
    # the parent is alive while it rewrites run/board/alive; the limit is max(15 s, 5 × interval)
    limit = max(15, 5 * CFG['interval'])
    try:
        limit = float(os.environ.get('BRG_SERVE_ALIVE_MAX') or limit)  # test hook
    except ValueError:
        pass
    check_ppid = not WIN and not os.environ.get('BRG_SERVE_NO_PPID')  # test hook

    def stop(*a):
        threading.Thread(target=srv.shutdown, daemon=True).start()

    def watch():
        alive = os.path.join(bd, os.path.basename(opt['alive']))
        while True:
            time.sleep(0.5)
            try:
                last = os.path.getmtime(alive)
            except OSError:
                last = started
            if time.time() - max(last, started) > limit or (check_ppid and os.getppid() != ppid0):
                stop()
                return

    # each brg board names its own ready file (ready.<its pid>): two boards in a project
    ready = os.path.join(bd, os.path.basename(opt['ready']))
    for s in ('SIGTERM', 'SIGHUP'):
        if hasattr(signal, s):
            signal.signal(getattr(signal, s), stop)
    threading.Thread(target=watch, daemon=True).start()
    try:
        atomic_write(os.path.join(bd, 'port'), '%d\n' % CFG['port'])
        atomic_write(ready, '%d\n%d\n%s' % (CFG['port'], os.getpid(), '%d\n' % busy if busy else ''))
    except OSError as e:
        say('── brg-serve: не удалось записать run/board/%s: %s' % (os.path.basename(ready), e), True)
        srv.server_close()
        return 4
    try:
        srv.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.unlink(ready)
        except OSError:
            pass
        srv.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
