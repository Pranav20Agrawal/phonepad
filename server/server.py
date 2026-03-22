# server.py — PhonePad Laptop Server
# Receives touch/gesture events from the PhonePad Flutter app over WebSocket
# and translates them into real Windows mouse/keyboard input.
#
# Dependencies: pip install websockets pynput zeroconf qrcode keyring pystray Pillow pyperclip
# Run: python server.py  (as normal user — NOT administrator)
# First run: python server.py --setup   (interactive setup wizard)
import asyncio
import json
import ctypes
import ctypes.wintypes
import socket
import threading
import secrets
import hashlib
import hmac
import time
import argparse
import logging
import ssl
import pathlib
import websockets
from pynput.mouse import Button, Controller as MouseController
from pynput.keyboard import Key, Controller as KeyboardController

# ── Optional imports ──────────────────────────────────────────────────
try:
    from zeroconf import ServiceInfo, Zeroconf
    _ZEROCONF_OK = True
except ImportError:
    _ZEROCONF_OK = False
    print("[PhonePad] ⚠ 'zeroconf' not installed — mDNS disabled. Run: pip install zeroconf")

try:
    import qrcode
    _QR_OK = True
except ImportError:
    _QR_OK = False
    print("[PhonePad] ⚠ 'qrcode' not installed — QR disabled. Run: pip install qrcode")

try:
    import keyring
    _KEYRING_OK = True
except ImportError:
    _KEYRING_OK = False
    print("[PhonePad] ⚠ 'keyring' not installed — PIN storage disabled. Run: pip install keyring")

try:
    import pystray
    from PIL import Image, ImageDraw
    _TRAY_OK = True
except ImportError:
    _TRAY_OK = False
    print("[PhonePad] ⚠ 'pystray' or 'Pillow' not installed — tray icon disabled.")
    print("           Run: pip install pystray Pillow")

try:
    import pyperclip
    _CLIP_OK = True
except ImportError:
    _CLIP_OK = False
    print("[PhonePad] ⚠ 'pyperclip' not installed — clipboard sync disabled.")
    print("           Run: pip install pyperclip")

# ── Logging setup ──────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="[PhonePad] %(message)s",
)
log = logging.getLogger("phonepad")

# ══════════════════════════════════════════════════════════════════════
# WINDOWS API CONSTANTS
# ══════════════════════════════════════════════════════════════════════
INPUT_MOUSE            = 0
MOUSEEVENTF_MOVE       = 0x0001
MOUSEEVENTF_ABSOLUTE   = 0x8000
MOUSEEVENTF_WHEEL      = 0x0800
MOUSEEVENTF_HWHEEL     = 0x1000
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP   = 0x0040

# ══════════════════════════════════════════════════════════════════════
# CTYPES STRUCTURES
# ══════════════════════════════════════════════════════════════════════
class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx",          ctypes.c_long),
        ("dy",          ctypes.c_long),
        ("mouseData",   ctypes.c_long),
        ("dwFlags",     ctypes.c_ulong),
        ("time",        ctypes.c_ulong),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]

class INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT)]

class INPUT(ctypes.Structure):
    _fields_ = [
        ("type",   ctypes.c_ulong),
        ("_input", INPUT_UNION),
    ]


# ══════════════════════════════════════════════════════════════════════
# BIOMETRIC UNLOCK — PASSWORD STORAGE & EXECUTION
# ══════════════════════════════════════════════════════════════════════

def _save_unlock_password(password: str) -> bool:
    """
    Store the Windows login password in keyring.
    We keep BOTH a hash (for future integrity checks) AND the plaintext
    (encrypted by the OS keychain) because we need to type it character
    by character into the lock screen.
    """
    if not _KEYRING_OK:
        log.error("keyring not available — cannot save unlock password.")
        return False
    try:
        salt = secrets.token_hex(16)
        pw_hash = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
        keyring.set_password(_KR_SERVICE, _KR_UNLOCK_SALT, salt)
        keyring.set_password(_KR_SERVICE, _KR_UNLOCK_HASH, pw_hash)
        keyring.set_password(_KR_SERVICE, _KR_UNLOCK_PW,   password)
        return True
    except Exception as e:
        log.error(f"Failed to save unlock password: {e}")
        return False


def _load_unlock_password() -> str | None:
    """Return the stored unlock password, or None if not configured."""
    if not _KEYRING_OK:
        return None
    try:
        return keyring.get_password(_KR_SERVICE, _KR_UNLOCK_PW)
    except Exception:
        return None


def _unlock_password_is_set() -> bool:
    return _load_unlock_password() is not None


def _delete_unlock_password():
    """Remove stored unlock password (called from setup --clear-unlock)."""
    if not _KEYRING_OK:
        return
    for key in [_KR_UNLOCK_HASH, _KR_UNLOCK_SALT, _KR_UNLOCK_PW]:
        try:
            keyring.delete_password(_KR_SERVICE, key)
        except Exception:
            pass


# ── Lock screen detection ─────────────────────────────────────────────
# WTSQuerySessionInformation with WTSConnectState returns the session
# state. Value 4 = WTSDisconnected (screen locked / RDP disconnect).
# We also check if the foreground window is NULL (0), which happens
# when the lock screen is the active surface.

_WTS_CURRENT_SERVER  = None   # use current server
_WTS_CURRENT_SESSION = ctypes.c_ulong(-1)
_WTSConnectState     = 8      # WTSConnectStateClass enum index

class _WTS_SESSION_STATE:
    Active       = 0
    Connected    = 1
    ConnectQuery = 2
    Shadow       = 3
    Disconnected = 4
    Idle         = 5
    Listen       = 6
    Reset        = 7
    Down         = 8
    Init         = 9

def _is_screen_locked() -> bool:
    try:
        # Method 1: Check via WTS session state
        import subprocess
        result = subprocess.run(
            ['powershell', '-NoProfile', '-NonInteractive', '-Command',
             '(Get-Process logonui -ErrorAction SilentlyContinue) -ne $null'],
            capture_output=True, text=True, timeout=3)
        if result.stdout.strip().lower() == 'true':
            return True

        # Method 2: OpenInputDesktop check
        h_desktop = ctypes.windll.user32.OpenInputDesktop(0, False, 0x0100)
        if h_desktop:
            ctypes.windll.user32.CloseDesktop(h_desktop)
            return False
        return True
    except Exception as e:
        log.warning(f"Lock state check failed: {e}")
        return True  # assume locked if check fails, safer


def _wake_screen():
    """
    Nudge the mouse to wake the display and bring up the lock screen UI.
    Uses a zero-delta relative move so the cursor doesn't actually move.
    """
    inp = INPUT()
    inp.type = INPUT_MOUSE
    inp._input.mi.dwFlags = MOUSEEVENTF_MOVE
    inp._input.mi.dx      = 1
    inp._input.mi.dy      = 0
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
    # nudge back
    inp._input.mi.dx = -1
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


# ── Unlock rate limiting ──────────────────────────────────────────────
def _check_unlock_rate_limit(remote_ip: str) -> tuple[bool, str]:
    """
    Return (allowed, reason). Resets the window after UNLOCK_RATE_WINDOW_SECS.
    """
    now = time.monotonic()
    with _unlock_lock:
        entry = _unlock_attempts.get(remote_ip, {
            "attempts": 0,
            "window_start": now,
            "locked_until": 0.0,
        })
        if now < entry["locked_until"]:
            remaining = int(entry["locked_until"] - now)
            return False, f"Too many unlock attempts. Try again in {remaining}s."
        if now - entry["window_start"] > UNLOCK_RATE_WINDOW_SECS:
            entry = {"attempts": 0, "window_start": now, "locked_until": 0.0}
        entry["attempts"] += 1
        if entry["attempts"] > UNLOCK_MAX_ATTEMPTS:
            entry["locked_until"] = now + UNLOCK_COOLDOWN_SECS
            entry["attempts"] = 0
            _unlock_attempts[remote_ip] = entry
            return False, f"Too many unlock attempts. Locked for {UNLOCK_COOLDOWN_SECS}s."
        _unlock_attempts[remote_ip] = entry
        return True, ""


# ── Main unlock sequence ──────────────────────────────────────────────
async def _perform_unlock(remote_ip: str) -> tuple[bool, str]:
    """
    Full unlock sequence. Returns (success, message).
    Called from handle_connection on the asyncio thread.

    Steps:
      1. Rate-limit check
      2. Password loaded check
      3. Confirm screen is actually locked
      4. Wake screen
      5. Wait for lock screen UI to be ready
      6. Type password + Enter
      7. Brief pause then check if unlock succeeded
    """
    # 1. Rate limit
    allowed, reason = _check_unlock_rate_limit(remote_ip)
    if not allowed:
        log.warning(f"Unlock rate limit hit for {remote_ip}: {reason}")
        return False, reason

    # 2. Password configured?
    password = _load_unlock_password()
    if not password:
        return False, "No unlock password configured. Run: python server.py --set-unlock-password"

    # 3. Is it actually locked?
    if not _is_screen_locked():
        log.info("Unlock requested but screen is not locked.")
        return True, "already_unlocked"

    log.info(f"Unlock sequence started from {remote_ip}")

    # 4. Wake screen
    _wake_screen()
    await asyncio.sleep(UNLOCK_WAKE_DELAY_MS / 1000)

    # 5. Wake and focus the password field
    keyboard.tap(Key.space)
    await asyncio.sleep(0.5)

    # Click the center of the screen to ensure focus
    virt_w = ctypes.windll.user32.GetSystemMetrics(0)
    virt_h = ctypes.windll.user32.GetSystemMetrics(1)
    cx = virt_w // 2
    cy = virt_h // 2
    ctypes.windll.user32.SetCursorPos(cx, cy)
    ctypes.windll.user32.mouse_event(0x0002, 0, 0, 0, 0)  # left down
    await asyncio.sleep(0.05)
    ctypes.windll.user32.mouse_event(0x0004, 0, 0, 0, 0)  # left up
    await asyncio.sleep(0.5)

    # Press Escape to dismiss Windows Hello / PIN overlay if present
    # and switch to password field
    keyboard.tap(Key.esc)
    await asyncio.sleep(0.3)

    # Click again to make sure password field is focused
    ctypes.windll.user32.mouse_event(0x0002, 0, 0, 0, 0)
    await asyncio.sleep(0.05)
    ctypes.windll.user32.mouse_event(0x0004, 0, 0, 0, 0)
    await asyncio.sleep(0.3)

    # Clear any existing input first
    keyboard.press(Key.ctrl)
    keyboard.tap('a')
    keyboard.release(Key.ctrl)
    await asyncio.sleep(0.1)

    # 6. Use schtasks to run a VBScript as SYSTEM which can type into the lock screen
    log.info(f"Typing password via scheduled task ({len(password)} chars)...")
    import tempfile, os

    # Write a VBScript that types the password
    vbs_content = f'''
Set shell = CreateObject("WScript.Shell")
WScript.Sleep 500
shell.SendKeys "{password.replace('"', '""').replace('+', '{+}').replace('^', '{^}').replace('%', '{%}').replace('~', '{~}').replace('(', '{(}').replace(')', '{)}').replace('[', '{[}').replace(']', '{]}').replace('{', '{{').replace('}', '}}')}"
WScript.Sleep 200
shell.SendKeys "{{ENTER}}"
'''
    vbs_path = os.path.join(tempfile.gettempdir(), 'phonepad_unlock.vbs')
    with open(vbs_path, 'w') as f:
        f.write(vbs_content)

    import subprocess
    # Delete any existing task first
    subprocess.run(
        ['schtasks', '/delete', '/tn', 'PhonePadUnlock', '/f'],
        capture_output=True)

    # Create a task that runs as SYSTEM immediately
    subprocess.run([
        'schtasks', '/create', '/tn', 'PhonePadUnlock',
        '/tr', f'wscript.exe "{vbs_path}"',
        '/sc', 'once',
        '/st', '00:00',
        '/ru', 'SYSTEM',
        '/f'
    ], capture_output=True)

    # Run it immediately
    result = subprocess.run(
        ['schtasks', '/run', '/tn', 'PhonePadUnlock'],
        capture_output=True, text=True)

    log.info(f"Scheduled task result: {result.returncode} {result.stdout.strip()}")
    await asyncio.sleep(2.0)

    # Cleanup
    subprocess.run(['schtasks', '/delete', '/tn', 'PhonePadUnlock', '/f'], capture_output=True)
    try:
        os.remove(vbs_path)
    except Exception:
        pass

    log.info("Unlock task completed.")

    # 7. Wait and verify
    await asyncio.sleep(2.0)
    if _is_screen_locked():
        log.warning("Unlock sequence completed but screen still appears locked.")
        return False, "Unlock may have failed — screen still locked after password entry."

    log.info("Unlock sequence completed successfully.")
    return True, "unlocked"

# ══════════════════════════════════════════════════════════════════════
# TLS / WSS — SELF-SIGNED CERTIFICATE
# ══════════════════════════════════════════════════════════════════════
# We generate a self-signed cert once, store it next to server.py, and
# reuse it on every subsequent start.  The Flutter app accepts it via
# a custom badCertificateCallback — safe for LAN use where you own both
# ends.  No external CA or openssl binary required; uses Python's built-
# in ssl.create_default_context + cryptography package if available,
# falling back to a subprocess openssl call.
#
# Cert files: phonepad.crt  (sent to phone as DER bytes on first connect)
#             phonepad.key  (private key, never leaves the server)

_CERT_DIR  = pathlib.Path(__file__).parent
_CERT_FILE = _CERT_DIR / "phonepad.crt"
_KEY_FILE  = _CERT_DIR / "phonepad.key"
_CERT_FINGERPRINT_KEY = "tls_cert_fingerprint"   # keyring key

try:
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.backends import default_backend
    import datetime as _dt
    _CRYPTO_OK = True
except ImportError:
    _CRYPTO_OK = False


def _generate_self_signed_cert():
    """
    Generate a 2048-bit RSA self-signed cert valid for 10 years.
    Writes phonepad.crt and phonepad.key beside server.py.
    Returns (cert_pem_path, key_pem_path) or raises on failure.
    """
    if _CRYPTO_OK:
        key = rsa.generate_private_key(
            public_exponent=65537, key_size=2048,
            backend=default_backend())
        key_pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption())

        subject = issuer = x509.Name([
            x509.NameAttribute(NameOID.COMMON_NAME, u"PhonePad"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, u"PhonePad"),
        ])
        now = _dt.datetime.utcnow()
        cert = (x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now)
            .not_valid_after(now + _dt.timedelta(days=3650))
            .add_extension(
                x509.SubjectAlternativeName([x509.DNSName(u"phonepad.local")]),
                critical=False)
            .sign(key, hashes.SHA256(), default_backend()))

        cert_pem = cert.public_bytes(serialization.Encoding.PEM)
        _CERT_FILE.write_bytes(cert_pem)
        _KEY_FILE.write_bytes(key_pem)
        log.info(f"Generated self-signed cert: {_CERT_FILE}")
        return cert_pem
    else:
        # Fallback: subprocess openssl (usually present on Windows via Git for Windows)
        import subprocess
        result = subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", str(_KEY_FILE), "-out", str(_CERT_FILE),
            "-days", "3650", "-nodes",
            "-subj", "/CN=PhonePad/O=PhonePad"],
            capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(
                f"openssl failed: {result.stderr}\n"
                "Install 'cryptography': pip install cryptography")
        log.info(f"Generated cert via openssl: {_CERT_FILE}")
        return _CERT_FILE.read_bytes()


def _cert_fingerprint(cert_pem: bytes) -> str:
    """Return SHA-256 fingerprint of the DER-encoded cert as hex pairs."""
    import hashlib as _hl
    if _CRYPTO_OK:
        cert = x509.load_pem_x509_certificate(cert_pem, default_backend())
        fp   = cert.fingerprint(hashes.SHA256())
    else:
        # strip PEM headers to get DER
        import base64
        b64 = b"".join(cert_pem.split(b"\n")
                       if b"\n" in cert_pem
                       else cert_pem.replace(b"\r\n", b"\n").split(b"\n"))
        b64 = b"".join(l for l in cert_pem.split(b"\n")
                       if l and not l.startswith(b"-----"))
        der = base64.b64decode(b64)
        fp  = bytes(_hl.sha256(der).digest())
    return ":".join(f"{b:02X}" for b in fp)


def _ensure_cert() -> tuple[pathlib.Path, pathlib.Path, str]:
    """
    Ensure cert+key exist. Generate if missing.
    Returns (cert_path, key_path, fingerprint_hex).
    """
    if not (_CERT_FILE.exists() and _KEY_FILE.exists()):
        cert_pem = _generate_self_signed_cert()
    else:
        cert_pem = _CERT_FILE.read_bytes()
    fp = _cert_fingerprint(cert_pem)
    return _CERT_FILE, _KEY_FILE, fp


def _build_ssl_context() -> ssl.SSLContext:
    """Build an SSLContext for the WebSocket server."""
    cert_path, key_path, _ = _ensure_cert()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(cert_path), str(key_path))
    return ctx


# ══════════════════════════════════════════════════════════════════════
# MULTI-MONITOR SUPPORT
# ══════════════════════════════════════════════════════════════════════
# EnumDisplayMonitors gives us all monitor rects. The user can pick
# which monitor the phone controls via the tray menu. Default = primary.

class _MonitorRect:
    def __init__(self, left, top, right, bottom, name=""):
        self.left   = left
        self.top    = top
        self.right  = right
        self.bottom = bottom
        self.name   = name
        self.width  = right  - left
        self.height = bottom - top

    def __repr__(self):
        return f"{self.name or 'Monitor'} {self.width}x{self.height} @({self.left},{self.top})"


def _enumerate_monitors() -> list[_MonitorRect]:
    """Return list of all connected monitors via EnumDisplayMonitors."""
    monitors = []

    MONITORENUMPROC = ctypes.WINFUNCTYPE(
        ctypes.c_bool,
        ctypes.c_ulong, ctypes.c_ulong,
        ctypes.POINTER(ctypes.wintypes.RECT), ctypes.c_double)

    def _callback(hMonitor, hdcMonitor, lprcMonitor, dwData):
        r = lprcMonitor.contents
        monitors.append(_MonitorRect(r.left, r.top, r.right, r.bottom))
        return True

    ctypes.windll.user32.EnumDisplayMonitors(
        None, None, MONITORENUMPROC(_callback), 0)

    # Label them
    for i, m in enumerate(monitors):
        m.name = f"Monitor {i+1}"

    return monitors if monitors else [_MonitorRect(
        0, 0,
        ctypes.windll.user32.GetSystemMetrics(0),
        ctypes.windll.user32.GetSystemMetrics(1),
        "Primary")]


# Active monitor — protected by a lock because the tray thread may write it
_active_monitor_lock = threading.Lock()
_active_monitor: _MonitorRect | None = None   # None = use first/primary

def _get_active_monitor() -> _MonitorRect:
    with _active_monitor_lock:
        if _active_monitor is not None:
            return _active_monitor
    monitors = _enumerate_monitors()
    return monitors[0] if monitors else _MonitorRect(
        0, 0,
        ctypes.windll.user32.GetSystemMetrics(0),
        ctypes.windll.user32.GetSystemMetrics(1))

def _set_active_monitor(m: _MonitorRect):
    global _active_monitor
    with _active_monitor_lock:
        _active_monitor = m
    log.info(f"Active monitor set to: {m}")


# ══════════════════════════════════════════════════════════════════════
# SCREEN METRICS
# ══════════════════════════════════════════════════════════════════════
_SCREEN_W = ctypes.windll.user32.GetSystemMetrics(0)
_SCREEN_H = ctypes.windll.user32.GetSystemMetrics(1)

# ══════════════════════════════════════════════════════════════════════
# PIN PAIRING — KEYRING STORAGE
# Service name used for all keyring entries.
# ══════════════════════════════════════════════════════════════════════
_KR_SERVICE       = "PhonePad"
_KR_PIN_KEY       = "pairing_pin_hash"     # stores sha256 hash of pairing PIN
_KR_SALT_KEY      = "pairing_pin_salt"     # random salt for the pairing PIN hash
_KR_PEERS_KEY     = "trusted_peer_ids"     # comma-separated list of trusted peer IDs
_KR_UNLOCK_HASH   = "unlock_pw_hash"       # sha256 hash of Windows login password
_KR_UNLOCK_SALT   = "unlock_pw_salt"       # random salt for the unlock password hash
_KR_UNLOCK_PW     = "unlock_pw_plain"      # encrypted plaintext (used for typing)

PIN_LENGTH            = 6                  # digits shown on screen
PIN_TIMEOUT_SECS      = 300                # PIN expires after this long
MAX_PIN_ATTEMPTS      = 5                  # brute-force cap per connection
PIN_COOLDOWN_SECS     = 30                 # wait after max attempts
PAIRING_SESSION_TOKEN_BYTES = 32           # bytes for session token

# ── Unlock constants ──────────────────────────────────────────────────
UNLOCK_RATE_WINDOW_SECS = 60    # rolling window for rate limiting
UNLOCK_MAX_ATTEMPTS     = 3     # max unlock attempts per window
UNLOCK_COOLDOWN_SECS    = 60    # cooldown after max attempts exceeded
UNLOCK_WAKE_DELAY_MS    = 350   # ms to wait after waking screen
UNLOCK_TYPE_DELAY_MS    = 120   # ms between each typed character

# ── Unlock rate-limit state ───────────────────────────────────────────
# Maps remote_ip -> {"attempts": int, "window_start": float, "locked_until": float}
_unlock_attempts: dict[str, dict] = {}
_unlock_lock = threading.Lock()

# ── Active pairing state ──────────────────────────────────────────────
# Only one pending PIN exists at a time across all connections.
_pending_pin: str | None = None
_pending_pin_expiry: float = 0.0
_pending_pin_lock = threading.Lock()

# ── Trusted sessions ──────────────────────────────────────────────────
# Maps session_token -> {"peer_id": str, "authenticated_at": float}
_trusted_sessions: dict[str, dict] = {}
_sessions_lock    = threading.Lock()

# ── Rate limiting: per-IP attempt counter ─────────────────────────────
# Maps remote_ip -> {"attempts": int, "cooldown_until": float}
_attempt_tracker: dict[str, dict] = {}
_attempts_lock   = threading.Lock()

def _load_pin_hash() -> tuple[str | None, str | None]:
    """Return (pin_hash, salt) from keyring, or (None, None) if not set."""
    if not _KEYRING_OK:
        return None, None
    pin_hash = keyring.get_password(_KR_SERVICE, _KR_PIN_KEY)
    salt     = keyring.get_password(_KR_SERVICE, _KR_SALT_KEY)
    return pin_hash, salt

def _save_pin(pin: str) -> bool:
    """Hash and store a new PIN. Returns True on success."""
    if not _KEYRING_OK:
        log.error("keyring not available — cannot save PIN.")
        return False
    salt     = secrets.token_hex(16)
    pin_hash = hashlib.sha256(f"{salt}{pin}".encode()).hexdigest()
    keyring.set_password(_KR_SERVICE, _KR_PIN_KEY,  pin_hash)
    keyring.set_password(_KR_SERVICE, _KR_SALT_KEY, salt)
    return True

def _verify_pin(candidate: str) -> bool:
    """Return True if candidate matches the stored PIN."""
    pin_hash, salt = _load_pin_hash()
    if pin_hash is None or salt is None:
        return False
    candidate_hash = hashlib.sha256(f"{salt}{candidate}".encode()).hexdigest()
    return hmac.compare_digest(candidate_hash, pin_hash)

def _pin_is_set() -> bool:
    pin_hash, _ = _load_pin_hash()
    return pin_hash is not None

def _load_trusted_peers() -> list[str]:
    if not _KEYRING_OK:
        return []
    raw = keyring.get_password(_KR_SERVICE, _KR_PEERS_KEY) or ""
    return [p for p in raw.split(",") if p]

def _save_trusted_peer(peer_id: str):
    peers = _load_trusted_peers()
    if peer_id not in peers:
        peers.append(peer_id)
        keyring.set_password(_KR_SERVICE, _KR_PEERS_KEY, ",".join(peers))

def _remove_trusted_peer(peer_id: str):
    peers = _load_trusted_peers()
    peers = [p for p in peers if p != peer_id]
    keyring.set_password(_KR_SERVICE, _KR_PEERS_KEY, ",".join(peers))

def _is_trusted_peer(peer_id: str) -> bool:
    return peer_id in _load_trusted_peers()

# ── Generate a fresh pairing PIN (shown on screen, expires) ───────────
def _generate_pairing_pin() -> str:
    global _pending_pin, _pending_pin_expiry
    with _pending_pin_lock:
        pin = "".join([str(secrets.randbelow(10)) for _ in range(PIN_LENGTH)])
        _pending_pin        = pin
        _pending_pin_expiry = time.monotonic() + PIN_TIMEOUT_SECS
    return pin

def _consume_pairing_pin(candidate: str) -> bool:
    """
    Check candidate against the pending PIN.
    Clears the PIN on success (single-use) or expiry.
    """
    global _pending_pin, _pending_pin_expiry
    with _pending_pin_lock:
        if _pending_pin is None:
            return False
        if time.monotonic() > _pending_pin_expiry:
            log.info("Pairing PIN expired.")
            _pending_pin = None
            return False
        ok = hmac.compare_digest(_pending_pin, candidate.strip())
        if ok:
            _pending_pin = None          # single-use
        return ok

# ── Session token helpers ─────────────────────────────────────────────
def _create_session(peer_id: str) -> str:
    token = secrets.token_hex(PAIRING_SESSION_TOKEN_BYTES)
    with _sessions_lock:
        _trusted_sessions[token] = {
            "peer_id":          peer_id,
            "authenticated_at": time.monotonic(),
        }
    return token

def _validate_session(token: str) -> bool:
    with _sessions_lock:
        return token in _trusted_sessions

def _revoke_session(token: str):
    with _sessions_lock:
        _trusted_sessions.pop(token, None)

# ── Rate limiting ─────────────────────────────────────────────────────
def _check_rate_limit(remote_ip: str) -> bool:
    """Return True if the IP is allowed to attempt pairing."""
    now = time.monotonic()
    with _attempts_lock:
        entry = _attempt_tracker.get(remote_ip, {"attempts": 0, "cooldown_until": 0.0})
        if now < entry["cooldown_until"]:
            remaining = int(entry["cooldown_until"] - now)
            log.warning(f"Rate limit active for {remote_ip} — {remaining}s remaining.")
            return False
        return True

def _record_failed_attempt(remote_ip: str):
    now = time.monotonic()
    with _attempts_lock:
        entry = _attempt_tracker.get(remote_ip, {"attempts": 0, "cooldown_until": 0.0})
        entry["attempts"] += 1
        if entry["attempts"] >= MAX_PIN_ATTEMPTS:
            entry["cooldown_until"] = now + PIN_COOLDOWN_SECS
            entry["attempts"]       = 0
            log.warning(f"Max PIN attempts reached for {remote_ip}. Cooldown {PIN_COOLDOWN_SECS}s.")
        _attempt_tracker[remote_ip] = entry

def _clear_attempts(remote_ip: str):
    with _attempts_lock:
        _attempt_tracker.pop(remote_ip, None)

# ══════════════════════════════════════════════════════════════════════
# NETWORK HELPERS
# ══════════════════════════════════════════════════════════════════════
def _get_local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return socket.gethostbyname(socket.gethostname())

# ══════════════════════════════════════════════════════════════════════
# QR CODE
# ══════════════════════════════════════════════════════════════════════
def _print_qr(url: str):
    if not _QR_OK:
        print(f"  Connect manually: {url}")
        return
    try:
        qr = qrcode.QRCode(version=None,
            error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=1, border=2)
        qr.add_data(url)
        qr.make(fit=True)
        matrix = qr.get_matrix()
        rows   = len(matrix)
        cols   = len(matrix[0]) if rows else 0
        print(f"\n  Scan to connect → {url}\n")
        for r in range(0, rows, 2):
            line = "  "
            for c in range(cols):
                top    = matrix[r][c]
                bottom = matrix[r + 1][c] if (r + 1) < rows else False
                if top and bottom:   line += "█"
                elif top:            line += "▀"
                elif bottom:         line += "▄"
                else:                line += " "
            print(line)
        print()
    except Exception as e:
        log.error(f"QR generation failed: {e}")
        print(f"  Connect manually: {url}")

# ══════════════════════════════════════════════════════════════════════
# mDNS / ZEROCONF
# ══════════════════════════════════════════════════════════════════════
_zeroconf_instance = None

def _start_mdns(ip: str, port: int):
    global _zeroconf_instance
    if not _ZEROCONF_OK:
        return
    try:
        info = ServiceInfo(
            type_      = "_phonepad._tcp.local.",
            name       = "PhonePad._phonepad._tcp.local.",
            addresses  = [socket.inet_aton(ip)],
            port       = port,
            properties = {b"version": b"1", b"name": b"PhonePad"},
            server     = f"{socket.gethostname()}.local.",
        )
        _zeroconf_instance = Zeroconf()
        _zeroconf_instance.register_service(info)
        log.info("mDNS active — phone can auto-discover this server.")
    except Exception as e:
        log.warning(f"mDNS registration failed: {e}")

def _stop_mdns():
    global _zeroconf_instance
    if _zeroconf_instance:
        try:
            _zeroconf_instance.unregister_all_services()
            _zeroconf_instance.close()
        except Exception:
            pass
        _zeroconf_instance = None

# ══════════════════════════════════════════════════════════════════════
# MOUSE INPUT via SendInput
# ══════════════════════════════════════════════════════════════════════
_extra_zero = ctypes.c_ulong(0)

def _send_relative_move(dx: int, dy: int):
    if dx == 0 and dy == 0:
        return
    inp = INPUT()
    inp.type = INPUT_MOUSE
    inp._input.mi.dx          = dx
    inp._input.mi.dy          = dy
    inp._input.mi.mouseData   = 0
    inp._input.mi.dwFlags     = MOUSEEVENTF_MOVE
    inp._input.mi.time        = 0
    inp._input.mi.dwExtraInfo = ctypes.pointer(_extra_zero)
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

def _fire_absolute_move():
    # MOUSEEVENTF_ABSOLUTE maps to the virtual screen (all monitors combined).
    # GetSystemMetrics(76/77) = SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN
    virt_w = ctypes.windll.user32.GetSystemMetrics(78)  # SM_CXVIRTUALSCREEN
    virt_h = ctypes.windll.user32.GetSystemMetrics(79)  # SM_CYVIRTUALSCREEN
    if virt_w <= 0: virt_w = _SCREEN_W
    if virt_h <= 0: virt_h = _SCREEN_H
    pt = ctypes.wintypes.POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
    norm_x = int(pt.x * 65535 / virt_w)
    norm_y = int(pt.y * 65535 / virt_h)
    inp = INPUT()
    inp.type = INPUT_MOUSE
    inp._input.mi.dx          = norm_x
    inp._input.mi.dy          = norm_y
    inp._input.mi.mouseData   = 0
    inp._input.mi.dwFlags     = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
    inp._input.mi.time        = 0
    inp._input.mi.dwExtraInfo = ctypes.pointer(_extra_zero)
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

def _send_scroll(amount_float: float, horizontal: bool = False):
    wheel_amount = int(amount_float * 40)
    if wheel_amount == 0:
        return
    inp = INPUT()
    inp.type = INPUT_MOUSE
    inp._input.mi.mouseData   = ctypes.c_long(wheel_amount)
    inp._input.mi.dwFlags     = MOUSEEVENTF_HWHEEL if horizontal else MOUSEEVENTF_WHEEL
    inp._input.mi.time        = 0
    inp._input.mi.dx          = 0
    inp._input.mi.dy          = 0
    inp._input.mi.dwExtraInfo = ctypes.pointer(_extra_zero)
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

def _send_middle_click():
    for flags in [MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP]:
        inp = INPUT()
        inp.type = INPUT_MOUSE
        inp._input.mi.dx          = 0
        inp._input.mi.dy          = 0
        inp._input.mi.mouseData   = 0
        inp._input.mi.dwFlags     = flags
        inp._input.mi.time        = 0
        inp._input.mi.dwExtraInfo = ctypes.pointer(_extra_zero)
        ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

# ══════════════════════════════════════════════════════════════════════
# PYNPUT CONTROLLERS
# ══════════════════════════════════════════════════════════════════════
mouse    = MouseController()
keyboard = KeyboardController()

# ══════════════════════════════════════════════════════════════════════
# ARROW KEY REPEAT
# ══════════════════════════════════════════════════════════════════════
SENSITIVITY      = 0.55
ARROW_INITIAL_DELAY_MS = 350
ARROW_REPEAT_MS        = 40

KEY_MAP = {
    "up":    Key.up,
    "down":  Key.down,
    "left":  Key.left,
    "right": Key.right,
}

async def _arrow_repeat(direction: str, held: set):
    key = KEY_MAP[direction]
    keyboard.tap(key)
    await asyncio.sleep(ARROW_INITIAL_DELAY_MS / 1000)
    while direction in held:
        keyboard.tap(key)
        await asyncio.sleep(ARROW_REPEAT_MS / 1000)

MEDIA_INITIAL_DELAY_MS = 400
MEDIA_REPEAT_MS        = 150

async def _media_repeat(key, token: str, held: set):
    keyboard.tap(key)
    await asyncio.sleep(MEDIA_INITIAL_DELAY_MS / 1000)
    while token in held:
        keyboard.tap(key)
        await asyncio.sleep(MEDIA_REPEAT_MS / 1000)

# ══════════════════════════════════════════════════════════════════════
# TEXT TYPING
# ══════════════════════════════════════════════════════════════════════
def _type_text(text: str):
    for ch in text:
        try:
            keyboard.type(ch)
        except Exception:
            pass

# ══════════════════════════════════════════════════════════════════════
# CUSTOM SHORTCUT EXECUTOR
# ══════════════════════════════════════════════════════════════════════
_MOD_MAP = {
    "ctrl":  Key.ctrl,
    "shift": Key.shift,
    "alt":   Key.alt,
    "win":   Key.cmd,
    "cmd":   Key.cmd,
    "meta":  Key.cmd,
}
_SPECIAL_KEY_MAP = {
    "enter":     Key.enter,
    "return":    Key.enter,
    "backspace": Key.backspace,
    "delete":    Key.delete,
    "del":       Key.delete,
    "escape":    Key.esc,
    "esc":       Key.esc,
    "tab":       Key.tab,
    "space":     Key.space,
    "home":      Key.home,
    "end":       Key.end,
    "pageup":    Key.page_up,
    "pagedown":  Key.page_down,
    "up":        Key.up,
    "down":      Key.down,
    "left":      Key.left,
    "right":     Key.right,
    "f1":  Key.f1,  "f2":  Key.f2,  "f3":  Key.f3,  "f4":  Key.f4,
    "f5":  Key.f5,  "f6":  Key.f6,  "f7":  Key.f7,  "f8":  Key.f8,
    "f9":  Key.f9,  "f10": Key.f10, "f11": Key.f11, "f12": Key.f12,
}

def _fire_shortcut(combo: str):
    parts = [p.strip().lower() for p in combo.split("+")]
    mods  = []
    key   = None
    for part in parts:
        if part in _MOD_MAP:
            mods.append(_MOD_MAP[part])
        elif part in _SPECIAL_KEY_MAP:
            key = _SPECIAL_KEY_MAP[part]
        elif len(part) == 1:
            key = part
    if key is None:
        return
    try:
        for mod in mods:
            keyboard.press(mod)
        keyboard.tap(key)
        for mod in reversed(mods):
            keyboard.release(mod)
    except Exception as e:
        log.error(f"Shortcut error '{combo}': {e}")

# ══════════════════════════════════════════════════════════════════════
# PER-CONNECTION STATE
# All mutable state that was previously global now lives here.
# ══════════════════════════════════════════════════════════════════════
class ConnectionState:
    def __init__(self):
        self.remainder_x    = 0.0
        self.remainder_y    = 0.0
        self.scroll_accum_y = 0.0
        self.scroll_accum_x = 0.0
        self.alt_held       = False
        self.zoom_active    = False
        self.arrow_held: set[str] = set()

    def reset(self):
        self.remainder_x    = 0.0
        self.remainder_y    = 0.0
        self.scroll_accum_y = 0.0
        self.scroll_accum_x = 0.0
        self.alt_held       = False
        self.zoom_active    = False
        self.arrow_held.clear()

    def release_all_held(self):
        """Force-release every held modifier/key. Called on disconnect."""
        if self.alt_held:
            try:
                keyboard.release(Key.alt)
            except Exception:
                pass
            self.alt_held = False

        if self.zoom_active:
            try:
                keyboard.release(Key.ctrl)
            except Exception:
                pass
            self.zoom_active = False

        # arrow_held stores both arrow directions AND media repeat tokens.
        # Build a complete map so every token gets a matching key release.
        _HELD_KEY_MAP = {
            "up":         Key.up,
            "down":       Key.down,
            "left":       Key.left,
            "right":      Key.right,
            "vol_up":     Key.media_volume_up,
            "vol_down":   Key.media_volume_down,
            "media_next": Key.media_next,
            "media_prev": Key.media_previous,
        }
        for token in list(self.arrow_held):
            key = _HELD_KEY_MAP.get(token)
            if key:
                try:
                    keyboard.release(key)
                except Exception:
                    pass
        self.arrow_held.clear()

SCROLL_THRESHOLD = 0.05

# ══════════════════════════════════════════════════════════════════════
# MAIN CONNECTION HANDLER
# ══════════════════════════════════════════════════════════════════════
async def handle_connection(websocket):
    remote_ip = websocket.remote_address[0]
    log.info(f"New connection from {remote_ip}")

    state = ConnectionState()

    # ── AUTHENTICATION HANDSHAKE ──────────────────────────────────────
    # Every new connection must authenticate before any input events
    # are processed. Two paths:
    #
    #   A) Returning device: sends {"type":"auth","peer_id":"...","token":"..."}
    #      Server validates the session token. If valid → authenticated.
    #
    #   B) New device: sends {"type":"pair","peer_id":"...","pin":"XXXXXX"}
    #      Server checks the pending pairing PIN. If valid:
    #        - Saves peer_id as trusted
    #        - Issues a session token sent back to the phone
    #        - Phone stores token in SharedPreferences for future reconnects
    #
    # If no PIN is set yet (first ever run), pairing is allowed once
    # without a PIN check so the user can do initial setup.

    authenticated = False
    session_token: str | None = None
    peer_id: str | None = None

    try:
        # Give the client 10 seconds to send the auth message
        try:
            raw = await asyncio.wait_for(websocket.recv(), timeout=10.0)
        except asyncio.TimeoutError:
            log.warning(f"Auth timeout from {remote_ip}")
            await websocket.send(json.dumps({
                "type": "auth_error",
                "reason": "timeout",
                "message": "Authentication timeout. Reconnect and send auth within 10s."
            }))
            return

        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            await websocket.send(json.dumps({
                "type": "auth_error",
                "reason": "bad_json",
                "message": "Expected JSON authentication message."
            }))
            return

        msg_type = msg.get("type")
        peer_id  = msg.get("peer_id", "")

        # ── Path A: returning device with session token ───────────────
        if msg_type == "auth":
            token = msg.get("token", "")
            if _validate_session(token) and _is_trusted_peer(peer_id):
                authenticated = True
                session_token = token
                log.info(f"✓ Authenticated returning device: {peer_id[:12]}…")
                _tray.set_connected(peer_id)
                await websocket.send(json.dumps({
                    "type": "auth_ok",
                    "message": "Authenticated."
                }))
            else:
                log.warning(f"Invalid session token from {remote_ip} peer={peer_id[:12] if peer_id else '?'}")
                await websocket.send(json.dumps({
                    "type": "auth_error",
                    "reason": "invalid_token",
                    "message": "Session expired or unknown device. Please pair again."
                }))
                return

        # ── Path B: new device pairing with PIN ───────────────────────
        elif msg_type == "pair":
            if not _check_rate_limit(remote_ip):
                await websocket.send(json.dumps({
                    "type": "auth_error",
                    "reason": "rate_limited",
                    "message": f"Too many attempts. Wait {PIN_COOLDOWN_SECS} seconds."
                }))
                return

            candidate_pin = msg.get("pin", "")

            # First-ever run: no PIN set yet → allow once to bootstrap
            if not _pin_is_set():
                log.info("No PIN set yet — allowing bootstrap pairing.")
                ok = True
            else:
                ok = _consume_pairing_pin(candidate_pin)

            if ok:
                _clear_attempts(remote_ip)
                _save_trusted_peer(peer_id)
                token = _create_session(peer_id)
                session_token = token
                authenticated = True
                log.info(f"✓ New device paired: {peer_id[:12]}…")
                _tray.set_connected(peer_id)
                _tray.clear_pairing()
                await websocket.send(json.dumps({
                    "type": "pair_ok",
                    "token": token,
                    "message": "Paired successfully. Token saved for future connections."
                }))
            else:
                _record_failed_attempt(remote_ip)
                # The PIN rotation loop will automatically issue a new PIN
                # within one cycle — no need to regenerate here.
                log.warning(f"Wrong/expired PIN from {remote_ip}.")
                await websocket.send(json.dumps({
                    "type": "auth_error",
                    "reason": "wrong_pin",
                    "message": (
                        "Incorrect or expired PIN. "
                        "Check the server window for the current PIN."
                    ),
                }))
                return

        # ── Unknown message type ──────────────────────────────────────
        else:
            await websocket.send(json.dumps({
                "type": "auth_error",
                "reason": "unexpected_message",
                "message": "Send {\"type\":\"auth\",...} or {\"type\":\"pair\",...} first."
            }))
            return

    except websockets.exceptions.ConnectionClosed:
        log.info(f"Connection closed during auth from {remote_ip}")
        return

    if not authenticated:
        return

    # ── MAIN EVENT LOOP ───────────────────────────────────────────────
    log.info(f"✓ Phone connected and authenticated from {remote_ip}")
    try:
        async for message in websocket:
            try:
                data       = json.loads(message)
                event_type = data.get("type")

                # ── CURSOR MOVEMENT ──────────────────────────────────
                if event_type == "move":
                    raw_dx = data.get("dx", 0) * SENSITIVITY
                    raw_dy = data.get("dy", 0) * SENSITIVITY
                    state.remainder_x += raw_dx
                    state.remainder_y += raw_dy
                    # Use round() instead of int() so 0.6 becomes 1 instead of 0
                    move_x = round(state.remainder_x)
                    move_y = round(state.remainder_y)
                    if move_x != 0 or move_y != 0:
                        _send_relative_move(move_x, move_y)
                        state.remainder_x -= move_x
                        state.remainder_y -= move_y
                        _fire_absolute_move()

                # ── CLICKS ───────────────────────────────────────────
                elif event_type == "left_click":
                    mouse.click(Button.left, 1)
                elif event_type == "right_click":
                    mouse.click(Button.right, 1)
                elif event_type == "double_click":
                    mouse.click(Button.left, 2)
                elif event_type == "middle_click":
                    _send_middle_click()

                # ── DRAG ─────────────────────────────────────────────
                elif event_type == "mouse_down":
                    mouse.press(Button.left)
                elif event_type == "mouse_up":
                    mouse.release(Button.left)

                # ── DOUBLE-TAP DRAG ───────────────────────────────────
                elif event_type == "double_click_drag_start":
                    mouse.press(Button.left)
                    await asyncio.sleep(0.03)
                    mouse.release(Button.left)
                    await asyncio.sleep(0.03)
                    ctypes.windll.user32.mouse_event(0x0001, 0, 0, 0, 0)
                    await asyncio.sleep(0.01)
                    mouse.press(Button.left)

                # ── SCROLL ────────────────────────────────────────────
                elif event_type == "scroll":
                    dy = data.get("dy", 0)
                    if data.get("natural", False):
                        dy = -dy
                    state.scroll_accum_y += dy
                    if abs(state.scroll_accum_y) >= SCROLL_THRESHOLD:
                        _send_scroll(-state.scroll_accum_y, horizontal=False)
                        state.scroll_accum_y = 0.0

                elif event_type == "scroll_x":
                    dx = data.get("dx", 0)
                    if data.get("natural", False):
                        dx = -dx
                    state.scroll_accum_x += dx
                    if abs(state.scroll_accum_x) >= SCROLL_THRESHOLD:
                        _send_scroll(state.scroll_accum_x, horizontal=True)
                        state.scroll_accum_x = 0.0

                # ── ALT+TAB ───────────────────────────────────────────
                elif event_type == "alt_tab":
                    if state.alt_held:
                        keyboard.release(Key.alt)
                        state.alt_held = False
                    keyboard.press(Key.alt)
                    keyboard.tap(Key.tab)
                    keyboard.release(Key.alt)
                elif event_type == "alt_down":
                    if not state.alt_held:
                        keyboard.press(Key.alt)
                        keyboard.tap(Key.tab)
                        state.alt_held = True
                elif event_type == "alt_tab_next":
                    if state.alt_held:
                        keyboard.tap(Key.tab)
                elif event_type == "alt_up":
                    if state.alt_held:
                        keyboard.release(Key.alt)
                        state.alt_held = False

                # ── ARROW KEYS ────────────────────────────────────────
                elif event_type == "arrow_up_down":
                    if "up" not in state.arrow_held:
                        state.arrow_held.add("up")
                        asyncio.ensure_future(_arrow_repeat("up", state.arrow_held))
                elif event_type == "arrow_up_up":
                    state.arrow_held.discard("up")
                elif event_type == "arrow_down_down":
                    if "down" not in state.arrow_held:
                        state.arrow_held.add("down")
                        asyncio.ensure_future(_arrow_repeat("down", state.arrow_held))
                elif event_type == "arrow_down_up":
                    state.arrow_held.discard("down")
                elif event_type == "arrow_left_down":
                    if "left" not in state.arrow_held:
                        state.arrow_held.add("left")
                        asyncio.ensure_future(_arrow_repeat("left", state.arrow_held))
                elif event_type == "arrow_left_up":
                    state.arrow_held.discard("left")
                elif event_type == "arrow_right_down":
                    if "right" not in state.arrow_held:
                        state.arrow_held.add("right")
                        asyncio.ensure_future(_arrow_repeat("right", state.arrow_held))
                elif event_type == "arrow_right_up":
                    state.arrow_held.discard("right")

                # ── ZOOM ─────────────────────────────────────────────
                elif event_type == "zoom_start":
                    if not state.zoom_active:
                        keyboard.press(Key.ctrl)
                        state.zoom_active = True
                elif event_type == "zoom_in":
                    if not state.zoom_active:
                        keyboard.press(Key.ctrl)
                        state.zoom_active = True
                    _send_scroll(3.0, horizontal=False)
                elif event_type == "zoom_out":
                    if not state.zoom_active:
                        keyboard.press(Key.ctrl)
                        state.zoom_active = True
                    _send_scroll(-3.0, horizontal=False)
                elif event_type == "zoom_end":
                    if state.zoom_active:
                        keyboard.release(Key.ctrl)
                        state.zoom_active = False

                # ── BUILT-IN SHORTCUTS ────────────────────────────────
                elif event_type == "shortcut_copy":
                    with keyboard.pressed(Key.ctrl):
                        keyboard.tap('c')
                elif event_type == "shortcut_paste":
                    with keyboard.pressed(Key.ctrl):
                        keyboard.tap('v')
                elif event_type == "shortcut_undo":
                    with keyboard.pressed(Key.ctrl):
                        keyboard.tap('z')
                elif event_type == "shortcut_close_tab":
                    with keyboard.pressed(Key.ctrl):
                        keyboard.tap('w')
                elif event_type == "shortcut_show_desktop":
                    with keyboard.pressed(Key.cmd):
                        keyboard.tap('d')

                # ── KEYBOARD / TYPING ─────────────────────────────────
                elif event_type == "type_text":
                    text = data.get("text", "")
                    if text:
                        _type_text(text)
                elif event_type == "key_newline":
                    keyboard.press(Key.shift)
                    keyboard.tap(Key.enter)
                    keyboard.release(Key.shift)
                elif event_type == "system_lock":
                    import subprocess
                    subprocess.Popen(['rundll32.exe', 'user32.dll,LockWorkStation'])
                elif event_type == "system_shutdown":
                    import subprocess
                    subprocess.Popen(['shutdown', '/s', '/t', '10', '/c', 'PhonePad shutdown'])
                elif event_type == "system_restart":
                    import subprocess
                    subprocess.Popen(['shutdown', '/r', '/t', '10', '/c', 'PhonePad restart'])
                elif event_type == "system_cancel_shutdown":
                    import subprocess
                    subprocess.Popen(['shutdown', '/a'])
                elif event_type == "brightness_set":
                    level = int(data.get("level", 50))
                    level = max(0, min(100, level))
                    import subprocess
                    ps = (
                        f"(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods)"
                        f".WmiSetBrightness(1,{level})"
                    )
                    subprocess.Popen(
                        ['powershell', '-NoProfile', '-NonInteractive', '-Command', ps],
                        capture_output=True)
                elif event_type == "volume_get":
                    import subprocess
                    ps = (
                        "try {"
                        "  Add-Type -TypeDefinition '"
                        "  using System.Runtime.InteropServices;"
                        "  public class AudioHelper {"
                        "    [DllImport(\"winmm.dll\")] public static extern int waveOutGetVolume(IntPtr h, out uint vol);"
                        "  }' ;"
                        "  $v = 0;"
                        "  [AudioHelper]::waveOutGetVolume([IntPtr]::Zero, [ref]$v);"
                        "  $left = $v -band 0xFFFF;"
                        "  $pct = [int]($left / 65535 * 100);"
                        "  Write-Output \"$pct false\""
                        "} catch { Write-Output '50 false' }"
                    )
                    try:
                        result = subprocess.run(
                            ['powershell', '-NoProfile', '-NonInteractive', '-Command', ps],
                            capture_output=True, text=True, timeout=2)
                        parts = result.stdout.strip().split()
                        vol_level = int(parts[0]) if parts and parts[0].isdigit() else 50
                        is_muted = parts[1].lower() == 'true' if len(parts) > 1 else False
                    except Exception:
                        vol_level = 50
                        is_muted = False
                    await websocket.send(json.dumps({
                        'type': 'volume_value',
                        'level': vol_level,
                        'muted': is_muted,
                    }))
                elif event_type == "battery_get":
                    import subprocess
                    ps = (
                        "$b = Get-WmiObject Win32_Battery;"
                        "if ($b) { Write-Output \"$($b.EstimatedChargeRemaining) $($b.BatteryStatus)\" }"
                        "else { Write-Output 'none' }"
                    )
                    try:
                        result = subprocess.run(
                            ['powershell', '-NoProfile', '-NonInteractive', '-Command', ps],
                            capture_output=True, text=True, timeout=3)
                        output = result.stdout.strip()
                        if not output or output == 'none':
                            await websocket.send(json.dumps({
                                'type': 'battery_value',
                                'level': -1,
                                'charging': False,
                                'available': False,
                            }))
                        else:
                            parts = output.split()
                            level = int(parts[0]) if parts else 0
                            # BatteryStatus: 1=discharging, 2=AC+charging, 6=AC+full, 7=AC+full, 8=charging
                            status = int(parts[1]) if len(parts) > 1 else 1
                            charging = status in (2, 6, 7, 8)
                            await websocket.send(json.dumps({
                                'type': 'battery_value',
                                'level': level,
                                'charging': charging,
                                'available': True,
                            }))
                    except Exception:
                        await websocket.send(json.dumps({
                            'type': 'battery_value',
                            'level': -1,
                            'charging': False,
                            'available': False,
                        }))
                elif event_type == "brightness_get":
                    import subprocess
                    ps = (
                        "(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness)"
                        ".CurrentBrightness"
                    )
                    result = subprocess.run(
                        ['powershell', '-NoProfile', '-NonInteractive', '-Command', ps],
                        capture_output=True, text=True, timeout=3)
                    level = 50
                    try:
                        level = int(result.stdout.strip())
                    except Exception:
                        pass
                    await websocket.send(json.dumps({
                        'type': 'brightness_value',
                        'level': level,
                    }))
                elif event_type == "key_backspace":
                    keyboard.tap(Key.backspace)
                elif event_type == "key_enter":
                    keyboard.tap(Key.enter)
                elif event_type == "key_tab":
                    keyboard.tap(Key.tab)
                elif event_type == "key_escape":
                    keyboard.tap(Key.esc)

                # ── MEDIA CONTROLS ────────────────────────────────────
                elif event_type == "media_play_pause":
                    keyboard.tap(Key.media_play_pause)
                elif event_type == "media_mute":
                    keyboard.tap(Key.media_volume_mute)
                elif event_type == "media_vol_up_down":
                    if "vol_up" not in state.arrow_held:
                        state.arrow_held.add("vol_up")
                        asyncio.ensure_future(_media_repeat(Key.media_volume_up, "vol_up", state.arrow_held))
                elif event_type == "media_vol_up_up":
                    state.arrow_held.discard("vol_up")
                elif event_type == "media_vol_down_down":
                    if "vol_down" not in state.arrow_held:
                        state.arrow_held.add("vol_down")
                        asyncio.ensure_future(_media_repeat(Key.media_volume_down, "vol_down", state.arrow_held))
                elif event_type == "media_vol_down_up":
                    state.arrow_held.discard("vol_down")
                elif event_type == "media_next_down":
                    if "media_next" not in state.arrow_held:
                        state.arrow_held.add("media_next")
                        asyncio.ensure_future(_media_repeat(Key.media_next, "media_next", state.arrow_held))
                elif event_type == "media_next_up":
                    state.arrow_held.discard("media_next")
                elif event_type == "media_prev_down":
                    if "media_prev" not in state.arrow_held:
                        state.arrow_held.add("media_prev")
                        asyncio.ensure_future(_media_repeat(Key.media_previous, "media_prev", state.arrow_held))
                elif event_type == "media_prev_up":
                    state.arrow_held.discard("media_prev")

                # ── CUSTOM SHORTCUT SLOTS ─────────────────────────────
                elif event_type == "custom_shortcut":
                    combo = data.get("combo", "")
                    if combo:
                        _fire_shortcut(combo)

                # ── BIOMETRIC UNLOCK ─────────────────────────────────
                elif event_type == "quick_unlock":
                    success, msg = await _perform_unlock(remote_ip)
                    await websocket.send(json.dumps({
                        "type":    "unlock_result",
                        "success": success,
                        "message": msg,
                    }))

                # ── PING / LATENCY ────────────────────────────────────
                # Phone sends {"type":"ping","ts":CLIENT_MS} every 2s.
                # Server echoes it back with its own timestamp added so
                # the phone can compute round-trip time.
                elif event_type == "ping":
                    await websocket.send(json.dumps({
                        "type":      "pong",
                        "client_ts": data.get("ts", 0),
                        "server_ts": int(time.monotonic() * 1000),
                    }))

                # ── CLIPBOARD SYNC ────────────────────────────────────
                # Phone → PC:  {"type":"clipboard_push","text":"..."}
                #   Sets Windows clipboard to the given text.
                # PC → Phone:  {"type":"clipboard_pull"}
                #   Server reads Windows clipboard and sends it back as
                #   {"type":"clipboard_content","text":"..."}
                elif event_type == "clipboard_push":
                    text = data.get("text", "")
                    if text and _CLIP_OK:
                        try:
                            pyperclip.copy(text)
                            log.debug(f"Clipboard set from phone ({len(text)} chars)")
                        except Exception as e:
                            log.warning(f"Clipboard push failed: {e}")
                    elif not _CLIP_OK:
                        log.warning("clipboard_push received but pyperclip not installed")

                elif event_type == "clipboard_pull":
                    if _CLIP_OK:
                        try:
                            text = pyperclip.paste() or ""
                            await websocket.send(json.dumps({
                                "type": "clipboard_content",
                                "text": text,
                            }))
                        except Exception as e:
                            log.warning(f"Clipboard pull failed: {e}")
                            await websocket.send(json.dumps({
                                "type":    "clipboard_content",
                                "text":    "",
                                "error":   str(e),
                            }))
                    else:
                        await websocket.send(json.dumps({
                            "type":  "clipboard_content",
                            "text":  "",
                            "error": "pyperclip not installed on server",
                        }))

                # ── PAIRING MANAGEMENT ────────────────────────────────
                elif event_type == "unpair":
                    # Authenticated device asking to remove itself
                    if session_token:
                        _revoke_session(session_token)
                    if peer_id:
                        _remove_trusted_peer(peer_id)
                    log.info(f"Device unpaired: {peer_id[:12] if peer_id else '?'}")
                    await websocket.send(json.dumps({"type": "unpaired"}))
                    return

            except json.JSONDecodeError:
                log.warning(f"Bad JSON: {message[:80]}")

    except websockets.exceptions.ConnectionClosedOK:
        log.info("Phone disconnected cleanly.")
    except websockets.exceptions.ConnectionClosedError as e:
        log.warning(f"Connection dropped: {e}")
    finally:
        state.release_all_held()
        state.reset()
        if session_token:
            # Don't revoke — token persists so the device can reconnect
            pass
        _tray.set_waiting()
        log.info("State reset. Waiting for next connection…\n")


# ══════════════════════════════════════════════════════════════════════
# TRAY ICON
# ══════════════════════════════════════════════════════════════════════
# Thread model:
#   - asyncio event loop runs on a dedicated background thread
#   - pystray.Icon.run() MUST run on the main thread (Windows requirement)
#   - TrayBridge is the shared state object; all mutations are protected
#     by a threading.Lock so neither thread sees a partial write
#
# Icon colours:
#   grey  = server waiting for a connection
#   green = phone connected and authenticated
#   amber = pairing PIN is currently displayed
#   red   = server error / stopped

class TrayState:
    WAITING   = "waiting"
    CONNECTED = "connected"
    PAIRING   = "pairing"
    ERROR     = "error"

class TrayBridge:
    """Shared mutable state between the asyncio thread and the tray thread."""
    def __init__(self):
        self._lock           = threading.Lock()
        self._state          = TrayState.WAITING
        self._peer_label     = ""          # short label shown in status menu item
        self._active_pin     = ""          # non-empty while pairing PIN is on screen
        self._loop: asyncio.AbstractEventLoop | None = None
        self._stop_event: asyncio.Event | None = None
        self._tray_icon = None  # pystray.Icon | None

    # ── State mutators (called from asyncio thread) ───────────────────
    def set_waiting(self):
        with self._lock:
            self._state      = TrayState.WAITING
            self._peer_label = ""
        self._refresh_icon()

    def set_connected(self, peer_id: str):
        with self._lock:
            self._state      = TrayState.CONNECTED
            self._peer_label = peer_id[:8] + "…" if len(peer_id) > 8 else peer_id
        self._refresh_icon()

    def set_pairing(self, pin: str):
        with self._lock:
            self._state      = TrayState.PAIRING
            self._active_pin = pin
        self._refresh_icon()

    def clear_pairing(self):
        with self._lock:
            if self._state == TrayState.PAIRING:
                self._state = TrayState.WAITING
            self._active_pin = ""
        self._refresh_icon()

    def set_error(self, msg: str = ""):
        with self._lock:
            self._state      = TrayState.ERROR
            self._peer_label = msg
        self._refresh_icon()

    # ── Asyncio loop registration ─────────────────────────────────────
    def register_loop(self, loop: asyncio.AbstractEventLoop,
                      stop_event: asyncio.Event):
        with self._lock:
            self._loop       = loop
            self._stop_event = stop_event

    # ── Tray icon registration ────────────────────────────────────────
    def register_tray(self, icon):
        with self._lock:
            self._tray_icon = icon

    # ── Menu helpers (called from tray thread) ────────────────────────
    def status_text(self) -> str:
        with self._lock:
            if self._state == TrayState.CONNECTED:
                return f"Connected  •  {self._peer_label}"
            if self._state == TrayState.PAIRING:
                return f"Pairing PIN: {self._active_pin}"
            if self._state == TrayState.ERROR:
                label = f" ({self._peer_label})" if self._peer_label else ""
                return f"Error{label}"
            return "Waiting for connection…"

    def pin_visible(self) -> bool:
        with self._lock:
            return bool(self._active_pin)

    def active_pin(self) -> str:
        with self._lock:
            return self._active_pin

    def request_quit(self):
        """Signal the asyncio loop to stop, then tell pystray to exit."""
        with self._lock:
            loop  = self._loop
            event = self._stop_event
            icon  = self._tray_icon
        if loop and event:
            loop.call_soon_threadsafe(event.set)
        if icon:
            icon.stop()

    # ── Icon image builder ────────────────────────────────────────────
    def _make_image(self) -> "Image.Image":
        """Draw a 64x64 icon. Colour encodes server state."""
        SIZE = 64
        with self._lock:
            state = self._state

        colour_map = {
            TrayState.WAITING:   (100, 120, 160),   # slate blue-grey
            TrayState.CONNECTED: (59,  245, 192),   # accent green
            TrayState.PAIRING:   (255, 184, 48),    # amber
            TrayState.ERROR:     (255, 77,  106),   # red
        }
        fill = colour_map.get(state, (100, 120, 160))

        img  = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Outer circle (status colour)
        draw.ellipse([2, 2, SIZE - 3, SIZE - 3], fill=fill)

        # Inner white touch-app icon — simplified hand silhouette
        # using a rounded rectangle for the palm and three small
        # rectangles for fingers
        cx, cy = SIZE // 2, SIZE // 2 + 4
        # Palm
        draw.rounded_rectangle(
            [cx - 10, cy - 6, cx + 10, cy + 14],
            radius=5, fill=(255, 255, 255))
        # Three finger stubs above palm
        for fx in [cx - 7, cx, cx + 7]:
            draw.rounded_rectangle(
                [fx - 3, cy - 16, fx + 3, cy - 2],
                radius=3, fill=(255, 255, 255))

        return img

    def _refresh_icon(self):
        """Redraw the tray icon image without rebuilding the menu."""
        with self._lock:
            icon = self._tray_icon
        if icon:
            try:
                icon.icon = self._make_image()
            except Exception:
                pass


# ── Singleton bridge shared across all modules in this file ──────────
_tray = TrayBridge()


# ── QR helper for tray (shows QR in a new terminal window) ───────────
def _show_qr_notification(ip: str, port: int):
    """
    Pop a small message box with the WS URL so the user can connect
    manually if they can't scan the QR from the terminal.
    Uses the Win32 MessageBox so no extra dependency is needed.
    """
    url = f"ws://{ip}:{port}"
    try:
        ctypes.windll.user32.MessageBoxW(
            0,
            f"Connect PhonePad to:\n\n{url}\n\nOr scan the QR code in the terminal window.",
            "PhonePad — Connection Info",
            0x40 | 0x1000   # MB_ICONINFORMATION | MB_SETFOREGROUND
        )
    except Exception as e:
        log.warning(f"Could not show message box: {e}")


# ── Change-PIN dialog via Win32 InputBox emulation ───────────────────
def _prompt_new_pin() -> str | None:
    """
    Ask for a new PIN using a simple Win32 InputBox script run via
    PowerShell. Returns the PIN string or None if cancelled / invalid.
    """
    import subprocess, tempfile, os
    ps_script = (
        "Add-Type -AssemblyName Microsoft.VisualBasic;"
        "$pin = [Microsoft.VisualBasic.Interaction]::InputBox("
        "   'Enter new 6-digit PIN:', 'PhonePad — Change PIN', '');"
        "Write-Output $pin"
    )
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive",
             "-Command", ps_script],
            capture_output=True, text=True, timeout=60)
        pin = result.stdout.strip()
        if len(pin) == PIN_LENGTH and pin.isdigit():
            return pin
    except Exception as e:
        log.warning(f"PIN prompt failed: {e}")
    return None


def _tray_generate_pin():
    """Generate a fresh pairing PIN and show it in a message box + tray."""
    pin = _generate_pairing_pin()
    _tray.set_pairing(pin)
    log.info(f"Tray: new pairing PIN generated: {pin}")
    print(f"  *** New pairing PIN: {pin}  (expires in {PIN_TIMEOUT_SECS}s) ***")
    try:
        ctypes.windll.user32.MessageBoxW(
            0,
            f"New pairing PIN:\n\n{pin}\n\nEnter this in the PhonePad app.\nExpires in {PIN_TIMEOUT_SECS} seconds.",
            "PhonePad — New Pairing PIN",
            0x40 | 0x1000)
    except Exception:
        pass


def _build_tray_menu(bridge: TrayBridge, ip: str, port: int):
    """Build the pystray Menu object. Called once; status item updates via icon.icon setter."""
    if not _TRAY_OK:
        return None

    def on_show_qr(icon, item):
        _show_qr_notification(ip, port)

    def on_change_pin(icon, item):
        pin = _prompt_new_pin()
        if pin:
            if _save_pin(pin):
                ctypes.windll.user32.MessageBoxW(
                    0, "PIN updated successfully.",
                    "PhonePad", 0x40 | 0x1000)
            else:
                ctypes.windll.user32.MessageBoxW(
                    0, "Failed to save PIN.",
                    "PhonePad", 0x10 | 0x1000)

    def on_set_unlock(icon, item):
        import getpass, subprocess
        # Use PowerShell SecureString prompt — avoids showing pw in console
        ps = (
            "Add-Type -AssemblyName System.Windows.Forms;"
            "$f=New-Object System.Windows.Forms.Form;"
            "$f.TopMost=$true;$f.Width=340;$f.Height=160;$f.Text='PhonePad — Unlock Password';"
            "$l=New-Object System.Windows.Forms.Label;$l.Text='Enter Windows login password:';$l.SetBounds(10,10,310,20);$f.Controls.Add($l);"
            "$t=New-Object System.Windows.Forms.TextBox;$t.PasswordChar='*';$t.SetBounds(10,35,300,25);$f.Controls.Add($t);"
            "$b=New-Object System.Windows.Forms.Button;$b.Text='Save';$b.SetBounds(220,80,80,30);$b.DialogResult='OK';$f.AcceptButton=$b;$f.Controls.Add($b);"
            "$r=$f.ShowDialog();if($r -eq 'OK'){Write-Output $t.Text}else{Write-Output ''}"
        )
        try:
            result = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                capture_output=True, text=True, timeout=120)
            pw = result.stdout.strip()
            if pw:
                if _save_unlock_password(pw):
                    ctypes.windll.user32.MessageBoxW(
                        0, "Unlock password saved. You can now use biometric unlock from the app.",
                        "PhonePad", 0x40 | 0x1000)
                else:
                    ctypes.windll.user32.MessageBoxW(
                        0, "Failed to save unlock password.", "PhonePad", 0x10 | 0x1000)
        except Exception as e:
            log.warning(f"Unlock password dialog failed: {e}")

    def on_clear_unlock(icon, item):
        _delete_unlock_password()
        ctypes.windll.user32.MessageBoxW(
            0, "Unlock password removed.", "PhonePad", 0x40 | 0x1000)

    def on_quit(icon, item):
        bridge.request_quit()

    # Build dynamic monitor submenu
    def _monitor_submenu():
        monitors = _enumerate_monitors()
        items = []
        def _make_action(mon):
            def _action(icon, item):
                _set_active_monitor(mon)
            return _action
        for m in monitors:
            items.append(pystray.MenuItem(str(m), _make_action(m)))
        return pystray.Menu(*items)

    return pystray.Menu(
        pystray.MenuItem(
            lambda item: bridge.status_text(),
            lambda: None,           # non-clickable status row
            enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Show connection info", on_show_qr),
        pystray.MenuItem("Generate new pairing PIN", lambda icon, item: _tray_generate_pin()),
        pystray.MenuItem("Active monitor", _monitor_submenu()),
        pystray.MenuItem("Change PIN…",      on_change_pin),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem(
            lambda item: "Set unlock password…" if not _unlock_password_is_set()
                         else "Change unlock password…",
            on_set_unlock),
        pystray.MenuItem(
            "Clear unlock password",
            on_clear_unlock,
            enabled=lambda item: _unlock_password_is_set()),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit PhonePad", on_quit),
    )


def _run_tray(bridge: TrayBridge, ip: str, port: int):
    """
    Build and run the pystray icon. Blocks until icon.stop() is called.
    Must be called from the MAIN thread on Windows.
    """
    if not _TRAY_OK:
        return

    menu = _build_tray_menu(bridge, ip, port)
    icon = pystray.Icon(
        name="PhonePad",
        icon=bridge._make_image(),
        title="PhonePad",
        menu=menu,
    )
    bridge.register_tray(icon)
    icon.run()          # blocks here until icon.stop() is called


# ══════════════════════════════════════════════════════════════════════
# UNLOCK PASSWORD SETUP
# ══════════════════════════════════════════════════════════════════════
def run_set_unlock_password():
    print()
    print("=" * 52)
    print("  PhonePad — Set Unlock Password")
    print("=" * 52)
    print()
    if not _KEYRING_OK:
        print("ERROR: 'keyring' package required. Run: pip install keyring")
        return
    print("  Enter your Windows login password.")
    print("  It will be stored encrypted in Windows Credential Manager.")
    print("  It is NEVER transmitted over the network.")
    print()
    import getpass
    pw = getpass.getpass("  Windows password: ")
    if not pw:
        print("  Cancelled — no password entered.")
        return
    confirm = getpass.getpass("  Confirm password: ")
    if pw != confirm:
        print("  Passwords do not match. Aborted.")
        return
    if _save_unlock_password(pw):
        print()
        print("  ✓ Unlock password saved to Windows Credential Manager.")
        print("  ✓ You can now use biometric unlock from the PhonePad app.")
    else:
        print("  ✗ Failed to save password.")
    print()


def run_clear_unlock_password():
    print()
    _delete_unlock_password()
    print("  ✓ Unlock password removed.")
    print()


# ══════════════════════════════════════════════════════════════════════
# SETUP WIZARD  (run with --setup)
# ══════════════════════════════════════════════════════════════════════
def run_setup():
    print()
    print("=" * 52)
    print("  PhonePad — First-time Setup")
    print("=" * 52)
    print()
    if not _KEYRING_OK:
        print("ERROR: 'keyring' package is required. Run: pip install keyring")
        return

    print("  Set the PIN that new devices must enter to pair.")
    print(f"  PIN must be exactly {PIN_LENGTH} digits.")
    print()
    while True:
        pin = input("  Enter PIN: ").strip()
        if len(pin) == PIN_LENGTH and pin.isdigit():
            confirm = input("  Confirm PIN: ").strip()
            if pin == confirm:
                break
            print("  PINs do not match. Try again.")
        else:
            print(f"  PIN must be exactly {PIN_LENGTH} digits.")

    if _save_pin(pin):
        print()
        print("  ✓ PIN saved to Windows Credential Manager.")
        print("  ✓ Setup complete. Run 'python server.py' to start.")
    else:
        print("  ✗ Failed to save PIN.")
    print()

# ══════════════════════════════════════════════════════════════════════
# SERVER STARTUP
# ══════════════════════════════════════════════════════════════════════
async def _server_main(stop_event: asyncio.Event, ip: str, port: int):
    """
    Core asyncio coroutine. Runs on a background thread.
    Exits cleanly when stop_event is set (triggered by tray Quit).
    """
    # Build SSL context — generates cert on first run
    try:
        ssl_ctx  = _build_ssl_context()
        _, _, fp = _ensure_cert()
        scheme   = "wss"
        log.info(f"TLS enabled. Cert fingerprint: {fp}")
    except Exception as e:
        log.warning(f"TLS setup failed ({e}) — falling back to unencrypted ws://")
        ssl_ctx = None
        fp      = None
        scheme  = "ws"

    ws_url = f"{scheme}://{ip}:{port}"

    # Detect monitors
    monitors = _enumerate_monitors()

    print()
    print("=" * 52)
    print("  PhonePad Server")
    print("=" * 52)
    print(f"  IP:      {ip}")
    print(f"  Port:    {port}")
    print(f"  TLS:     {'wss:// (encrypted) ✓' if ssl_ctx else 'ws:// (unencrypted)'}")
    if fp:
        fp_short = fp.replace(":", "")[:16] + "…"
        print(f"  Cert:    {fp_short}")
    print(f"  Screens: {len(monitors)} monitor{'s' if len(monitors) != 1 else ''}")
    for m in monitors:
        print(f"           {m}")
    if _pin_is_set():
        print("  Auth:    PIN pairing enabled ✓")
    else:
        print("  Auth:    ⚠ No PIN set — run with --setup first")
        print("           First connection will pair without PIN check.")
    if _unlock_password_is_set():
        print("  Unlock:  Biometric unlock enabled ✓")
    else:
        print("  Unlock:  ⚠ Not configured — run with --set-unlock-password")
    print("=" * 52)
    _print_qr(ws_url)

    threading.Thread(target=_start_mdns, args=(ip, port), daemon=True).start()

    # ── Pairing PIN loop ──────────────────────────────────────────────
    # Keep generating a fresh PIN every PIN_TIMEOUT_SECS until at least
    # one device has successfully paired. Once a trusted peer exists,
    # the loop stops — returning devices authenticate via session token.
    async def _pin_rotation_loop():
        while True:
            # Only stop if trusted peers exist AND there are active sessions.
            # If sessions are empty (e.g. after server restart with stale peer),
            # keep showing PIN so device can re-pair.
            if _load_trusted_peers() and _trusted_sessions:
                _tray.clear_pairing()
                log.info("Trusted device exists with active session — PIN rotation stopped.")
                return

            pin = _generate_pairing_pin()
            print(f"  Pairing PIN: {pin}  (valid for {PIN_TIMEOUT_SECS}s, auto-refreshes)")
            _tray.set_pairing(pin)

            # Wait for the PIN to expire, then loop and issue a new one.
            # Checks every second so we stop promptly once a device pairs.
            for _ in range(PIN_TIMEOUT_SECS):
                await asyncio.sleep(1)
                if _load_trusted_peers() and _trusted_sessions:
                    _tray.clear_pairing()
                    log.info("Device paired — PIN rotation stopped.")
                    print("  ✓ Device paired. PIN rotation stopped.\n")
                    return

            log.info("Pairing PIN expired — generating new one.")
            print()  # blank line before next PIN for readability

    try:
        serve_kwargs = {"ssl": ssl_ctx} if ssl_ctx else {}
        async with websockets.serve(
        handle_connection, "0.0.0.0", port,
        ping_interval=20,
        ping_timeout=60,
        **serve_kwargs):
            log.info("Waiting for phone connection…")
            print("  → Scan the QR above, tap Auto-Discover, or enter IP manually.\n")
            asyncio.ensure_future(_pin_rotation_loop())
            await stop_event.wait()          # blocks until tray Quit is clicked
    finally:
        _stop_mdns()
        log.info("Server stopped.")


def _run_server_thread(stop_event_holder: list, ip: str, port: int):
    """
    Entry point for the background asyncio thread.
    Creates its own event loop, runs _server_main, then exits.
    """
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    stop_event = asyncio.Event()
    stop_event_holder.append(stop_event)

    # Give the tray bridge a reference to this loop + event
    _tray.register_loop(loop, stop_event)

    try:
        loop.run_until_complete(_server_main(stop_event, ip, port))
    finally:
        loop.close()


if __name__ == "__main__":
    import signal as _signal

    parser = argparse.ArgumentParser(description="PhonePad Server")
    parser.add_argument("--setup",                 action="store_true", help="Run first-time setup wizard")
    parser.add_argument("--set-unlock-password",   action="store_true", help="Store Windows login password for biometric unlock")
    parser.add_argument("--clear-unlock-password", action="store_true", help="Remove stored unlock password")
    parser.add_argument("--debug",                 action="store_true", help="Enable debug logging")
    parser.add_argument("--no-tray",               action="store_true", help="Disable system tray icon (terminal mode)")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    if args.setup:
        run_setup()
        raise SystemExit(0)

    if args.set_unlock_password:
        run_set_unlock_password()
        raise SystemExit(0)

    if args.clear_unlock_password:
        run_clear_unlock_password()
        raise SystemExit(0)

    HOST = "0.0.0.0"
    PORT = 8765
    local_ip = _get_local_ip()

    if args.no_tray or not _TRAY_OK:
        # ── Terminal mode ─────────────────────────────────────────────
        if not _TRAY_OK and not args.no_tray:
            log.warning("pystray/Pillow not available — running in terminal mode.")

        # Use a threading.Event so the SIGINT handler can signal the
        # asyncio loop from outside without calling loop methods directly.
        _term_stop = threading.Event()

        def _terminal_sigint(signum, frame):
            print()
            log.info("Ctrl+C received — shutting down...")
            _term_stop.set()

        _signal.signal(_signal.SIGINT,  _terminal_sigint)
        _signal.signal(_signal.SIGTERM, _terminal_sigint)

        async def _terminal_main():
            stop = asyncio.Event()
            _tray.register_loop(asyncio.get_event_loop(), stop)

            # Poll the threading.Event every 0.5s and forward it to
            # the asyncio stop_event so _server_main exits cleanly.
            async def _watch_sigint():
                while not _term_stop.is_set():
                    await asyncio.sleep(0.5)
                stop.set()

            await asyncio.gather(
                _server_main(stop, local_ip, PORT),
                _watch_sigint(),
                return_exceptions=True)

        try:
            asyncio.run(_terminal_main())
        except (KeyboardInterrupt, SystemExit):
            pass
        finally:
            log.info("PhonePad stopped.")

    else:
        # ── Tray mode: asyncio on background thread, tray on main thread ──
        stop_event_holder: list = []

        server_thread = threading.Thread(
            target=_run_server_thread,
            args=(stop_event_holder, local_ip, PORT),
            daemon=True,
            name="phonepad-server",
        )
        server_thread.start()

        # Small grace period so the asyncio loop registers itself with
        # the bridge before the tray icon is built.
        import time as _time
        _time.sleep(0.3)

        # Install SIGINT handler AFTER the tray thread is ready.
        # pystray's Win32 message loop swallows Ctrl+C by default —
        # this handler tells the bridge to quit cleanly instead.
        def _tray_sigint(signum, frame):
            print()
            log.info("Ctrl+C received — shutting down...")
            _tray.request_quit()

        _signal.signal(_signal.SIGINT,  _tray_sigint)
        _signal.signal(_signal.SIGTERM, _tray_sigint)

        # Build and run tray on main thread (Windows requirement).
        # Ctrl+C now routes through _tray_sigint → _tray.request_quit()
        # → icon.stop() which unblocks this call.
        try:
            _run_tray(_tray, local_ip, PORT)
        except (KeyboardInterrupt, SystemExit):
            _tray.request_quit()

        # Wait for the server thread to finish its cleanup
        server_thread.join(timeout=3)
        log.info("PhonePad exited.")