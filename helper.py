#!/usr/bin/env python3
"""Multi-backend torrent client helper for the Omarchy Torrents bar plugin.

Talks to Transmission, qBittorrent, and Deluge over their respective
WebUI/RPC APIs using only the standard library. Always prints a single JSON
object to stdout; callers should treat a non-zero exit as an unexpected
failure (argparse error, uncaught exception) rather than the normal
ok:false-with-message path used for expected failures (auth, timeouts).
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "omarchy-torrents"
CONFIG_PATH = CONFIG_DIR / "config.toml"


def ensure_config_dir():
    # 0700: config.toml lists each client's host/port/username, which
    # shouldn't be listable by other local users either.
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)


KINDS = ("transmission", "qbittorrent", "deluge")

# Passwords never touch config.toml. They live only in the desktop's Secret
# Service -- GNOME Keyring by default on Omarchy (gnome-keyring-daemon,
# unlocked via PAM at login; KWallet works too) -- accessed via secret-tool
# and keyed by client id. There is no plaintext fallback: if the keyring
# can't take a password (missing secret-tool, locked, timeout, ...),
# save_clients() raises CredentialStorageError and the save is aborted
# rather than writing the password to disk.
SECRET_SERVICE = "omarchy-torrents"

STRING_FIELDS = ("id", "name", "kind", "host", "path", "username")
INT_FIELDS = ("port",)
BOOL_FIELDS = ("ssl",)


# --------------------------------------------------------------------------
# Secret Service (keyring) helpers
# --------------------------------------------------------------------------
# Thin wrappers around the `secret-tool` CLI (part of libsecret), which talks
# to whatever Secret Service provider is running -- GNOME Keyring
# (gnome-keyring-daemon) on a stock Omarchy install, KWallet on others.
# Every call is best-effort: on any failure these return empty/false rather
# than raising, so a locked or missing keyring surfaces as a normal
# CredentialStorageError in save_clients() instead of crashing the plugin.

def keyring_available():
    return shutil.which("secret-tool") is not None


def secret_store(client_id, label, password):
    try:
        proc = subprocess.run(
            ["secret-tool", "store", "--label", label, "service", SECRET_SERVICE, "client_id", client_id],
            input=password.encode(), capture_output=True, timeout=10,
        )
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def secret_lookup(client_id):
    try:
        proc = subprocess.run(
            ["secret-tool", "lookup", "service", SECRET_SERVICE, "client_id", client_id],
            capture_output=True, timeout=10,
        )
        if proc.returncode == 0:
            return proc.stdout.decode(errors="ignore").rstrip("\n")
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ""


def secret_clear(client_id):
    try:
        subprocess.run(
            ["secret-tool", "clear", "service", SECRET_SERVICE, "client_id", client_id],
            capture_output=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


class BackendError(Exception):
    pass


class CredentialStorageError(Exception):
    """Raised when a password can't be stored in the Secret Service. There
    is no plaintext fallback, so this always aborts the save."""


def out(payload):
    sys.stdout.write(json.dumps(payload) + "\n")


def fail(message, code=None):
    payload = {"ok": False, "error": str(message)}
    if code:
        payload["code"] = code
    out(payload)
    return 0  # expected failures are not process errors


# --------------------------------------------------------------------------
# Config storage
# --------------------------------------------------------------------------

def toml_escape(s):
    # Escapes a value for embedding in a TOML basic ("...") string. Beyond
    # backslash/quote, a literal control character (e.g. a pasted newline in
    # a client name) would otherwise produce invalid TOML -- load_clients()
    # would then fail to parse the whole file and silently return an empty
    # client list, wiping every saved connection.
    result = str(s).replace("\\", "\\\\").replace('"', '\\"')
    return "".join(
        {"\n": "\\n", "\r": "\\r", "\t": "\\t"}.get(ch, f"\\u{ord(ch):04x}" if ord(ch) < 0x20 else ch)
        for ch in result
    )


def slugify(name, existing_ids):
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "client"
    slug = base
    n = 2
    while slug in existing_ids:
        slug = f"{base}-{n}"
        n += 1
    return slug


def load_clients():
    if not CONFIG_PATH.exists():
        return []

    try:
        with open(CONFIG_PATH, "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return []

    clients = []
    for entry in data.get("clients", []):
        if not isinstance(entry, dict) or "id" not in entry:
            continue
        client_id = str(entry.get("id", ""))
        # The keyring is the only source of truth for a password. A
        # "password" field in the TOML entry itself (e.g. hand-edited, or
        # left over from a config.toml predating this plugin's Secret
        # Service integration) is never read -- there is no code path left
        # that stores one, so honoring one here would be the one remaining
        # way a plaintext password could still get used.
        clients.append({
            "id": client_id,
            "name": str(entry.get("name", "")),
            "kind": str(entry.get("kind", "transmission")),
            "host": str(entry.get("host", "")),
            "port": int(entry.get("port", 0) or 0),
            "path": str(entry.get("path", "")),
            "username": str(entry.get("username", "")),
            "password": secret_lookup(client_id),
            "ssl": bool(entry.get("ssl", False)),
        })
    return clients


def save_clients(clients, keyring_id=None):
    # Only the client actually being added/edited (keyring_id) gets its
    # secret re-written; every other entry's password is already correct in
    # the keyring from its own last save, so touching it again here would
    # just be a wasted secret-tool round trip per unrelated client.
    #
    # Fail-closed, unconditionally: if that one client has a password to
    # store and the keyring can't take it (missing secret-tool, locked,
    # timeout, ...), the whole save is aborted -- nothing is written. There
    # is no plaintext fallback and no opt-in to one; a password is either in
    # the Secret Service or it isn't saved at all.
    ensure_config_dir()
    lines = []
    for c in clients:
        password = c.get("password", "")
        if c["id"] == keyring_id:
            if password:
                label = f"Omarchy Torrents: {c.get('name') or c.get('id')}"
                if not secret_store(c["id"], label, password):
                    raise CredentialStorageError(
                        "Secure credential storage is unavailable.\n"
                        "Secret-tool is missing, the keyring is locked, or the "
                        "request timed out or failed.\n"
                        "The password was not saved. Unlock or start your keyring "
                        "and try again."
                    )
            elif keyring_available():
                secret_clear(c["id"])

        lines.append("[[clients]]")
        for key in STRING_FIELDS:
            lines.append(f'{key} = "{toml_escape(c.get(key, ""))}"')
        for key in INT_FIELDS:
            lines.append(f"{key} = {int(c.get(key, 0) or 0)}")
        for key in BOOL_FIELDS:
            lines.append(f"{key} = {'true' if c.get(key) else 'false'}")
        lines.append("")

    # Create/truncate with 0600 from the first syscall rather than writing
    # then chmod'ing after: the latter would leave a brief window where a
    # newly-created file sits at the umask's default (often world-readable)
    # mode. config.toml never holds a password, but the file lists hosts,
    # ports, and usernames, which don't belong to other local users either.
    fd = os.open(CONFIG_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(CONFIG_PATH, 0o600)  # belt-and-suspenders for a pre-existing file


def public_client(c):
    """Client fields safe to hand to the UI (no password)."""
    return {k: c[k] for k in ("id", "name", "kind", "host", "port", "path", "ssl", "username")}


def find_client(clients, client_id):
    for c in clients:
        if c["id"] == client_id:
            return c
    return None


# --------------------------------------------------------------------------
# Deluge alt-speed emulation state
# --------------------------------------------------------------------------
# Deluge's core has no built-in "alternative speed limits" profile the way
# Transmission and qBittorrent do -- it only exposes one persistent pair of
# limits. We emulate a toggle by remembering the limits in effect before
# switching to a fixed low-speed profile, so turning it back off restores
# exactly what was there before.

DELUGE_ALT_STATE_PATH = CONFIG_DIR / "deluge-alt-state.json"
DELUGE_ALT_DOWN_LIMIT_KIB = 100
DELUGE_ALT_UP_LIMIT_KIB = 50


def load_deluge_alt_state():
    try:
        with open(DELUGE_ALT_STATE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_deluge_alt_state(state):
    ensure_config_dir()
    with open(DELUGE_ALT_STATE_PATH, "w", encoding="utf-8") as f:
        json.dump(state, f)


# --------------------------------------------------------------------------
# HTTP helpers (stdlib only)
# --------------------------------------------------------------------------

def http_request(url, method="GET", data=None, headers=None, timeout=10):
    # Returns the response headers as the native email.message.Message
    # object rather than a plain dict: HTTP header names are case-insensitive
    # and Message.get() honors that, but dict(resp.headers) would flatten it
    # to whatever case the particular server happened to send (some clients
    # send "Set-Cookie", others "set-cookie"), silently breaking lookups.
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, resp.headers, body
    except urllib.error.HTTPError as e:
        return e.code, e.headers if e.headers is not None else {}, e.read()
    except urllib.error.URLError as e:
        raise BackendError(f"Connection failed: {e.reason}")
    except OSError as e:
        raise BackendError(f"Connection failed: {e}")


def build_multipart(fields, files):
    """fields: {name: value}. files: {name: (filename, content_type, data)}."""
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        parts.append(str(value).encode() + b"\r\n")
    for name, (filename, content_type, data) in files.items():
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n".encode()
        )
        parts.append(data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    content_type = f"multipart/form-data; boundary={boundary}"
    return body, content_type


# --------------------------------------------------------------------------
# Backends
# --------------------------------------------------------------------------

class Backend:
    def __init__(self, client):
        self.client = client
        scheme = "https" if client.get("ssl") else "http"
        self.base = f"{scheme}://{client['host']}:{client['port']}"

    def list_torrents(self):
        raise NotImplementedError

    def add_magnet(self, uri):
        raise NotImplementedError

    def add_torrent_file(self, data, filename):
        raise NotImplementedError

    def set_action(self, ids, op):
        raise NotImplementedError

    def get_alt_speed_enabled(self):
        raise NotImplementedError

    def set_alt_speed_enabled(self, enabled):
        raise NotImplementedError


class TransmissionBackend(Backend):
    STATUS_MAP = {
        0: "paused", 1: "checking", 2: "checking",
        3: "queued", 4: "downloading", 5: "queued", 6: "seeding",
    }
    FIELDS = [
        "hashString", "name", "status", "percentDone", "rateDownload",
        "rateUpload", "eta", "uploadRatio", "sizeWhenDone", "error", "errorString",
    ]

    def __init__(self, client):
        super().__init__(client)
        self.url = self.base + (client.get("path") or "/transmission/rpc")
        self._session_id = None

    def _call(self, method, arguments=None):
        payload = json.dumps({"method": method, "arguments": arguments or {}}).encode()
        for attempt in range(2):
            headers = {"Content-Type": "application/json"}
            if self._session_id:
                headers["X-Transmission-Session-Id"] = self._session_id
            if self.client.get("username"):
                token = base64.b64encode(
                    f"{self.client['username']}:{self.client.get('password', '')}".encode()
                ).decode()
                headers["Authorization"] = f"Basic {token}"

            status, resp_headers, body = http_request(self.url, "POST", payload, headers)
            if status == 409:
                session_id = resp_headers.get("X-Transmission-Session-Id")
                if session_id and attempt == 0:
                    self._session_id = session_id
                    continue
                raise BackendError("Could not negotiate a Transmission session")
            if status == 401:
                raise BackendError("Authentication failed (check username/password)")
            if status != 200:
                raise BackendError(f"HTTP error {status}")
            try:
                result = json.loads(body.decode())
            except json.JSONDecodeError:
                raise BackendError("Transmission returned an unreadable response")
            if result.get("result") != "success":
                raise BackendError(f"RPC error: {result.get('result')}")
            return result.get("arguments", {})
        raise BackendError("Failed to reach Transmission")

    def list_torrents(self):
        torrents = self._call("torrent-get", {"fields": self.FIELDS}).get("torrents", [])
        out_list = []
        for t in torrents:
            status = self.STATUS_MAP.get(t.get("status", 0), "unknown")
            if t.get("error"):
                status = "error"
            out_list.append({
                "id": t.get("hashString", ""),
                "name": t.get("name", ""),
                "status": status,
                "progress": t.get("percentDone", 0.0),
                "sizeBytes": t.get("sizeWhenDone", 0),
                "downloadRate": t.get("rateDownload", 0),
                "uploadRate": t.get("rateUpload", 0),
                "eta": t.get("eta", -1),
                "ratio": t.get("uploadRatio", 0.0),
                "error": t.get("errorString", "") or "",
            })
        return out_list

    def add_magnet(self, uri):
        self._call("torrent-add", {"filename": uri})

    def add_torrent_file(self, data, filename):
        self._call("torrent-add", {"metainfo": base64.b64encode(data).decode()})

    def set_action(self, ids, op):
        method = {
            "pause": "torrent-stop",
            "resume": "torrent-start",
            "remove": "torrent-remove",
            "remove-data": "torrent-remove",
        }[op]
        args = {"ids": ids}
        if op == "remove-data":
            args["delete-local-data"] = True
        self._call(method, args)

    def get_alt_speed_enabled(self):
        result = self._call("session-get", {"fields": ["alt-speed-enabled"]})
        return bool(result.get("alt-speed-enabled"))

    def set_alt_speed_enabled(self, enabled):
        self._call("session-set", {"alt-speed-enabled": bool(enabled)})


class QbittorrentBackend(Backend):
    STATE_MAP = {
        "downloading": "downloading", "metaDL": "downloading", "forcedDL": "downloading", "allocating": "downloading",
        "uploading": "seeding", "forcedUP": "seeding", "stalledUP": "seeding",
        "stalledDL": "downloading",
        "pausedDL": "paused", "pausedUP": "paused",
        "stoppedDL": "paused", "stoppedUP": "paused",  # qBittorrent 5.0 renamed paused* to stopped*
        "queuedDL": "queued", "queuedUP": "queued",
        "checkingDL": "checking", "checkingUP": "checking", "checkingResumeData": "checking",
        "error": "error", "missingFiles": "error", "unknown": "unknown",
    }

    def __init__(self, client):
        super().__init__(client)
        self._cookie = None

    def _headers(self, extra=None):
        headers = {"Referer": self.base, "Origin": self.base}
        if self._cookie:
            headers["Cookie"] = self._cookie
        if extra:
            headers.update(extra)
        return headers

    def _login(self):
        # Login is documented as a plain form POST (not multipart); qBittorrent's
        # host/Referer check also requires Referer/Origin to match the target host.
        body = urllib.parse.urlencode({
            "username": self.client.get("username", ""),
            "password": self.client.get("password", ""),
        }).encode()
        status, headers, resp_body = http_request(
            self.base + "/api/v2/auth/login", "POST", body,
            self._headers({"Content-Type": "application/x-www-form-urlencoded"}),
        )
        # Newer qBittorrent returns 204 No Content on a successful login
        # (older versions returned 200 with body "Ok.").
        if status not in (200, 204):
            raise BackendError(f"qBittorrent login failed (HTTP {status})")
        set_cookie = headers.get("Set-Cookie", "")
        # Newer qBittorrent names the cookie QBT_SID_<port>; older versions
        # just used SID.
        match = re.search(r"(?:QBT_SID_\d+|SID)=[^;]+", set_cookie)
        if not match:
            if resp_body.decode(errors="ignore").strip().lower() == "fails.":
                raise BackendError("qBittorrent authentication failed (check username/password)")
            raise BackendError("qBittorrent did not return a session cookie")
        self._cookie = match.group(0)

    def _raw_request(self, path, method="GET", data=None, extra_headers=None, retried=False):
        if not self._cookie:
            self._login()
        status, headers, body = http_request(
            self.base + path, method, data, self._headers(extra_headers),
        )
        if status in (401, 403) and not retried:
            self._cookie = None
            return self._raw_request(path, method, data, extra_headers, retried=True)
        return status, body

    def _request(self, path, method="GET", data=None, extra_headers=None):
        status, body = self._raw_request(path, method, data, extra_headers)
        if status != 200:
            raise BackendError(f"qBittorrent request failed (HTTP {status})")
        return body

    def _try_paths(self, path_field_pairs):
        # qBittorrent 5.0 renamed torrents/pause+resume to torrents/stop+start
        # and fully removed the old names (404, not just deprecated) -- try
        # the current name first and fall back to the pre-5.0 one.
        last_status = None
        for path, fields in path_field_pairs:
            body = urllib.parse.urlencode(fields).encode()
            status, _ = self._raw_request(path, "POST", body, {"Content-Type": "application/x-www-form-urlencoded"})
            if status == 200:
                return
            last_status = status
        raise BackendError(f"qBittorrent request failed (HTTP {last_status})")

    def list_torrents(self):
        body = self._request("/api/v2/torrents/info")
        torrents = json.loads(body.decode())
        out_list = []
        for t in torrents:
            out_list.append({
                "id": t.get("hash", ""),
                "name": t.get("name", ""),
                "status": self.STATE_MAP.get(t.get("state", ""), "unknown"),
                "progress": t.get("progress", 0.0),
                "sizeBytes": t.get("size", 0),
                "downloadRate": t.get("dlspeed", 0),
                "uploadRate": t.get("upspeed", 0),
                "eta": t.get("eta", -1) if t.get("eta", -1) not in (8640000, 8640000000) else -1,
                "ratio": t.get("ratio", 0.0),
                "error": "" if t.get("state") not in ("error", "missingFiles") else "Torrent error",
            })
        return out_list

    def add_magnet(self, uri):
        body, content_type = build_multipart({"urls": uri}, {})
        self._request("/api/v2/torrents/add", "POST", body, {"Content-Type": content_type})

    def add_torrent_file(self, data, filename):
        body, content_type = build_multipart(
            {}, {"torrents": (filename, "application/x-bittorrent", data)},
        )
        self._request("/api/v2/torrents/add", "POST", body, {"Content-Type": content_type})

    def set_action(self, ids, op):
        hashes = "|".join(ids)
        if op == "pause":
            self._try_paths([
                ("/api/v2/torrents/stop", {"hashes": hashes}),
                ("/api/v2/torrents/pause", {"hashes": hashes}),
            ])
        elif op == "resume":
            self._try_paths([
                ("/api/v2/torrents/start", {"hashes": hashes}),
                ("/api/v2/torrents/resume", {"hashes": hashes}),
            ])
        elif op in ("remove", "remove-data"):
            delete_files = "true" if op == "remove-data" else "false"
            body = urllib.parse.urlencode({"hashes": hashes, "deleteFiles": delete_files}).encode()
            self._request("/api/v2/torrents/delete", "POST", body, {"Content-Type": "application/x-www-form-urlencoded"})

    def get_alt_speed_enabled(self):
        body = self._request("/api/v2/transfer/speedLimitsMode")
        return body.decode(errors="ignore").strip() == "1"

    def set_alt_speed_enabled(self, enabled):
        desired = "1" if enabled else "0"
        # setSpeedLimitsMode (explicit set) is newer; older qBittorrent only has
        # toggleSpeedLimitsMode, so fall back to toggling only if needed.
        status, _ = self._raw_request(f"/api/v2/transfer/setSpeedLimitsMode?mode={desired}", "POST")
        if status == 200:
            return
        if self.get_alt_speed_enabled() != enabled:
            self._request("/api/v2/transfer/toggleSpeedLimitsMode", "POST")


class DelugeBackend(Backend):
    STATE_MAP = {
        "Downloading": "downloading", "Seeding": "seeding", "Paused": "paused",
        "Checking": "checking", "Queued": "queued", "Error": "error",
        "Allocating": "downloading", "Moving": "downloading",
    }
    STATUS_KEYS = [
        "name", "state", "progress", "download_payload_rate",
        "upload_payload_rate", "eta", "ratio", "total_wanted", "message",
    ]

    def __init__(self, client):
        super().__init__(client)
        self.url = self.base + "/json"
        self._cookie = None
        self._req_id = 0

    def _headers(self):
        headers = {"Content-Type": "application/json"}
        if self._cookie:
            headers["Cookie"] = self._cookie
        return headers

    def _login(self):
        self._req_id += 1
        payload = json.dumps({
            "method": "auth.login", "params": [self.client.get("password", "")], "id": self._req_id,
        }).encode()
        status, headers, body = http_request(self.url, "POST", payload, {"Content-Type": "application/json"})
        if status != 200:
            raise BackendError(f"Deluge login failed (HTTP {status})")
        set_cookie = headers.get("Set-Cookie", "")
        match = re.search(r"_session_id=[^;]+", set_cookie)
        if not match:
            raise BackendError("Deluge did not return a session cookie")
        self._cookie = match.group(0)
        result = json.loads(body.decode())
        if result.get("error"):
            raise BackendError("Deluge authentication failed (check password)")
        if result.get("result") is False:
            raise BackendError("Deluge authentication failed (check password)")
        self._ensure_connected()

    def _ensure_connected(self):
        # deluge-web is a separate process from the core daemon and is not
        # connected to it by default -- every core.* call fails with
        # "Unknown method" until web.connect is called once per session.
        if self._call("web.connected", []):
            return
        hosts = self._call("web.get_hosts", []) or []
        if not hosts:
            raise BackendError("Deluge Web UI has no daemon host configured")
        self._call("web.connect", [hosts[0][0]])

    def _call(self, method, params, retried=False):
        if not self._cookie:
            self._login()
        self._req_id += 1
        payload = json.dumps({"method": method, "params": params, "id": self._req_id}).encode()
        status, headers, body = http_request(self.url, "POST", payload, self._headers())
        if status in (401, 403) and not retried:
            self._cookie = None
            return self._call(method, params, retried=True)
        if status != 200:
            raise BackendError(f"Deluge request failed (HTTP {status})")
        try:
            result = json.loads(body.decode())
        except json.JSONDecodeError:
            raise BackendError("Deluge returned an unreadable response")
        if result.get("error"):
            raise BackendError(str(result["error"].get("message", result["error"])))
        return result.get("result")

    def list_torrents(self):
        statuses = self._call("core.get_torrents_status", [{}, self.STATUS_KEYS]) or {}
        out_list = []
        for torrent_id, t in statuses.items():
            state = t.get("state", "")
            status = self.STATE_MAP.get(state, "unknown")
            # Deluge's "message" field is a general status string (it reads
            # "OK" when everything is fine), not an error flag -- only trust
            # the dedicated "Error" state, and only surface message text then.
            out_list.append({
                "id": torrent_id,
                "name": t.get("name", ""),
                "status": status,
                "progress": (t.get("progress", 0.0) or 0.0) / 100.0,
                "sizeBytes": t.get("total_wanted", 0),
                "downloadRate": t.get("download_payload_rate", 0),
                "uploadRate": t.get("upload_payload_rate", 0),
                "eta": t.get("eta", -1),
                "ratio": t.get("ratio", 0.0),
                "error": t.get("message", "") if status == "error" else "",
            })
        return out_list

    def add_magnet(self, uri):
        self._call("core.add_torrent_magnet", [uri, {}])

    def add_torrent_file(self, data, filename):
        self._call("core.add_torrent_file", [filename, base64.b64encode(data).decode(), {}])

    def set_action(self, ids, op):
        if op == "pause":
            self._call("core.pause_torrent", [ids])
        elif op == "resume":
            self._call("core.resume_torrent", [ids])
        elif op in ("remove", "remove-data"):
            remove_data = op == "remove-data"
            for torrent_id in ids:
                self._call("core.remove_torrent", [torrent_id, remove_data])

    def get_alt_speed_enabled(self):
        state = load_deluge_alt_state()
        return bool(state.get(self.client["id"], {}).get("enabled"))

    def set_alt_speed_enabled(self, enabled):
        state = load_deluge_alt_state()
        client_id = self.client["id"]
        entry = state.get(client_id, {})
        if enabled:
            if entry.get("enabled"):
                return
            config = self._call("core.get_config", []) or {}
            state[client_id] = {
                "enabled": True,
                "savedDown": config.get("max_download_speed", -1),
                "savedUp": config.get("max_upload_speed", -1),
            }
            self._call("core.set_config", [{
                "max_download_speed": DELUGE_ALT_DOWN_LIMIT_KIB,
                "max_upload_speed": DELUGE_ALT_UP_LIMIT_KIB,
            }])
        else:
            if not entry.get("enabled"):
                return
            self._call("core.set_config", [{
                "max_download_speed": entry.get("savedDown", -1),
                "max_upload_speed": entry.get("savedUp", -1),
            }])
            state[client_id] = {"enabled": False}
        save_deluge_alt_state(state)


BACKENDS = {
    "transmission": TransmissionBackend,
    "qbittorrent": QbittorrentBackend,
    "deluge": DelugeBackend,
}


def make_backend(client):
    cls = BACKENDS.get(client.get("kind"))
    if cls is None:
        raise BackendError(f"Unknown client kind: {client.get('kind')}")
    return cls(client)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_clients(args):
    clients = load_clients()
    out({"ok": True, "clients": [public_client(c) for c in clients]})
    return 0


def client_args_to_dict(args):
    password = args.password
    return {
        "name": args.name or "",
        "kind": args.kind,
        "host": args.host or "",
        "port": args.port or 0,
        "path": args.path or "",
        "username": args.username or "",
        "password": password if password is not None else "",
        "ssl": bool(args.ssl),
    }


def cmd_probe(args):
    if args.id:
        clients = load_clients()
        existing = find_client(clients, args.id)
        if not existing:
            return fail(f"No client with id {args.id}")
        # Start from the saved record (this is the only place the real
        # password lives) and layer the form's current field values on top,
        # so testing mid-edit reflects unsaved changes. A blank/omitted
        # password means "keep testing with what's already stored" rather
        # than testing with no credentials at all.
        client = dict(existing)
        client.update(client_args_to_dict(args))
        if not args.password:
            client["password"] = existing.get("password", "")
    else:
        client = client_args_to_dict(args)
        client["id"] = "__probe__"
    try:
        backend = make_backend(client)
        torrents = backend.list_torrents()
        out({"ok": True, "torrentCount": len(torrents)})
    except BackendError as e:
        return fail(e)
    return 0


def cmd_add_client(args):
    clients = load_clients()
    new_fields = client_args_to_dict(args)

    if args.id:
        existing = find_client(clients, args.id)
        if not existing:
            return fail(f"No client with id {args.id}")
        # Keep the stored password when the caller didn't supply a new one.
        if args.password is None:
            new_fields["password"] = existing.get("password", "")
        existing.update(new_fields)
        changed_id = args.id
    else:
        existing_ids = {c["id"] for c in clients}
        new_fields["id"] = slugify(new_fields["name"] or new_fields["kind"], existing_ids)
        clients.append(new_fields)
        changed_id = new_fields["id"]

    try:
        save_clients(clients, keyring_id=changed_id)
    except CredentialStorageError as e:
        return fail(e, code="keyring_unavailable")
    out({"ok": True, "clients": [public_client(c) for c in clients]})
    return 0


def cmd_remove_client(args):
    clients = load_clients()
    remaining = [c for c in clients if c["id"] != args.id]
    if len(remaining) == len(clients):
        return fail(f"No client with id {args.id}")
    secret_clear(args.id)
    save_clients(remaining)
    out({"ok": True, "clients": [public_client(c) for c in remaining]})
    return 0


def cmd_status(args):
    clients = load_clients()
    client = find_client(clients, args.id)
    if not client:
        return fail(f"No client with id {args.id}")
    try:
        backend = make_backend(client)
        torrents = backend.list_torrents()
    except BackendError as e:
        return fail(e)
    try:
        alt_speed_enabled = backend.get_alt_speed_enabled()
    except BackendError:
        alt_speed_enabled = False
    totals = {
        "down": sum(t["downloadRate"] for t in torrents),
        "up": sum(t["uploadRate"] for t in torrents),
    }
    out({
        "ok": True, "clientId": client["id"], "clientName": client["name"],
        "torrents": torrents, "totals": totals, "altSpeedEnabled": alt_speed_enabled,
    })
    return 0


def cmd_add_magnet(args):
    clients = load_clients()
    client = find_client(clients, args.id)
    if not client:
        return fail(f"No client with id {args.id}")
    try:
        make_backend(client).add_magnet(args.magnet)
        out({"ok": True})
    except BackendError as e:
        return fail(e)
    return 0


def cmd_add_file(args):
    clients = load_clients()
    client = find_client(clients, args.id)
    if not client:
        return fail(f"No client with id {args.id}")
    path = Path(args.path)
    if not path.is_file():
        return fail(f"File not found: {args.path}")
    try:
        data = path.read_bytes()
        make_backend(client).add_torrent_file(data, path.name)
        out({"ok": True})
    except (BackendError, OSError) as e:
        return fail(e)
    return 0


def cmd_torrent_action(args):
    clients = load_clients()
    client = find_client(clients, args.id)
    if not client:
        return fail(f"No client with id {args.id}")
    ids = [t for t in args.torrent_ids.split(",") if t]
    if not ids:
        return fail("No torrent ids given")
    try:
        make_backend(client).set_action(ids, args.op)
        out({"ok": True})
    except BackendError as e:
        return fail(e)
    return 0


def cmd_set_alt_speed(args):
    clients = load_clients()
    client = find_client(clients, args.id)
    if not client:
        return fail(f"No client with id {args.id}")
    try:
        make_backend(client).set_alt_speed_enabled(args.enabled == "true")
        out({"ok": True})
    except BackendError as e:
        return fail(e)
    return 0


# --------------------------------------------------------------------------
# CLI argument parsing
# --------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Omarchy Torrents plugin helper")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("clients")

    def add_connection_args(p, id_required=False):
        p.add_argument("--id", required=id_required)
        p.add_argument("--name")
        p.add_argument("--kind", choices=KINDS, default="transmission")
        p.add_argument("--host")
        p.add_argument("--port", type=int)
        p.add_argument("--path", default="")
        p.add_argument("--username", default="")
        # Passed as a plain argument rather than over stdin: briefly visible
        # to other local processes (e.g. via `ps`) for this short-lived call,
        # an accepted tradeoff on a single-user desktop -- a stdin-based
        # approach was tried first but deadlocked in practice.
        p.add_argument("--password")
        p.add_argument("--ssl", action="store_true")

    p_probe = sub.add_parser("probe")
    add_connection_args(p_probe)

    p_add = sub.add_parser("add-client")
    add_connection_args(p_add)

    p_remove = sub.add_parser("remove-client")
    p_remove.add_argument("--id", required=True)

    p_status = sub.add_parser("status")
    p_status.add_argument("--id", required=True)

    p_magnet = sub.add_parser("add-magnet")
    p_magnet.add_argument("--id", required=True)
    p_magnet.add_argument("--magnet", required=True)

    p_file = sub.add_parser("add-file")
    p_file.add_argument("--id", required=True)
    p_file.add_argument("--path", required=True)

    p_action = sub.add_parser("torrent-action")
    p_action.add_argument("--id", required=True)
    p_action.add_argument("--op", required=True, choices=["pause", "resume", "remove", "remove-data"])
    p_action.add_argument("--torrent-ids", required=True)

    p_alt_speed = sub.add_parser("set-alt-speed")
    p_alt_speed.add_argument("--id", required=True)
    p_alt_speed.add_argument("--enabled", required=True, choices=["true", "false"])

    return parser.parse_args()


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def main():
    args = parse_args()
    handlers = {
        "clients": cmd_clients,
        "probe": cmd_probe,
        "add-client": cmd_add_client,
        "remove-client": cmd_remove_client,
        "status": cmd_status,
        "add-magnet": cmd_add_magnet,
        "add-file": cmd_add_file,
        "torrent-action": cmd_torrent_action,
        "set-alt-speed": cmd_set_alt_speed,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main() or 0)
