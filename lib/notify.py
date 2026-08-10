#!/usr/bin/env python3
"""Deliver an alert to every configured channel.

Channels live in /etc/ai-terminal/channels.json (0600, root-only). Any channel
that is absent or misconfigured is skipped silently — one broken channel must
never suppress the others, because the whole point is that the message arrives.

FCM is sent directly from the machine using a messaging-only service account.
That avoids requiring a Cloud Function, and therefore avoids requiring the Blaze
plan. The credential is deliberately NOT a full Admin SDK key: it can send
notifications and nothing else, so a compromised host cannot read the database.

Device tokens are pushed to the machine by the app over SSH; this agent never
reads Firebase. Send-only, zero read access.

Standard library only.
"""

from __future__ import annotations

import base64
import json
import os
import smtplib
import sys
import time
import urllib.parse
import urllib.request
from email.message import EmailMessage

CHANNELS = os.environ.get("CHANNELS_FILE", "/etc/ai-terminal/channels.json")
FCM_KEY = os.environ.get("FCM_KEY_FILE", "/etc/ai-terminal/fcm.json")
TIMEOUT = 20


def _load(path: str) -> dict:
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001 — absent config is a valid state
        return {}


# ── Telegram ────────────────────────────────────────────────────────────────
def send_telegram(cfg: dict, message: str) -> bool:
    token, chat_id = cfg.get("token"), cfg.get("chatId")
    if not token or not chat_id:
        return False
    try:
        data = urllib.parse.urlencode({"chat_id": chat_id, "text": message}).encode()
        urllib.request.urlopen(
            f"https://api.telegram.org/bot{token}/sendMessage", data=data, timeout=TIMEOUT
        )
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"telegram failed: {exc}", file=sys.stderr)
        return False


# ── SMTP ────────────────────────────────────────────────────────────────────
def send_email(cfg: dict, message: str, subject: str) -> bool:
    host = cfg.get("host")
    if not host:
        return False
    try:
        msg = EmailMessage()
        msg["From"] = cfg.get("from", cfg.get("user", ""))
        msg["To"] = ", ".join(cfg.get("to", []))
        msg["Subject"] = subject
        msg.set_content(message)

        port = int(cfg.get("port", 587))
        if port == 465:
            server = smtplib.SMTP_SSL(host, port, timeout=TIMEOUT)
        else:
            server = smtplib.SMTP(host, port, timeout=TIMEOUT)
            server.starttls()
        if cfg.get("user"):
            server.login(cfg["user"], cfg.get("password", ""))
        server.send_message(msg)
        server.quit()
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"smtp failed: {exc}", file=sys.stderr)
        return False


# ── FCM (HTTP v1, service-account JWT → OAuth token) ─────────────────────────
def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _access_token(sa: dict) -> str | None:
    """Exchange a service-account JWT for an OAuth token.

    RS256 signing without a crypto library is not possible, so this shells out to
    `openssl`, which is present on every machine that can run Docker.
    """
    import subprocess

    now = int(time.time())
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64url(
        json.dumps(
            {
                "iss": sa["client_email"],
                "scope": "https://www.googleapis.com/auth/firebase.messaging",
                "aud": "https://oauth2.googleapis.com/token",
                "iat": now,
                "exp": now + 3600,
            }
        ).encode()
    )
    signing_input = f"{header}.{claims}".encode()

    try:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", "/dev/stdin"],
            input=sa["private_key"].encode() + b"\0" + signing_input,
            capture_output=True,
            timeout=TIMEOUT,
        )
        # openssl cannot take key and payload on one stream; use a temp key file.
        import tempfile

        with tempfile.NamedTemporaryFile("w", delete=True) as key_file:
            key_file.write(sa["private_key"])
            key_file.flush()
            proc = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", key_file.name],
                input=signing_input,
                capture_output=True,
                timeout=TIMEOUT,
            )
        if proc.returncode != 0:
            return None
        jwt = f"{header}.{claims}.{_b64url(proc.stdout)}"

        data = urllib.parse.urlencode(
            {"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": jwt}
        ).encode()
        with urllib.request.urlopen(
            "https://oauth2.googleapis.com/token", data=data, timeout=TIMEOUT
        ) as resp:
            return json.load(resp).get("access_token")
    except Exception as exc:  # noqa: BLE001
        print(f"fcm token failed: {exc}", file=sys.stderr)
        return None


def send_fcm(cfg: dict, message: str, data: dict) -> bool:
    tokens = cfg.get("tokens") or []
    if not tokens or not os.path.exists(FCM_KEY):
        return False

    sa = _load(FCM_KEY)
    project = sa.get("project_id")
    token = _access_token(sa)
    if not project or not token:
        return False

    url = f"https://fcm.googleapis.com/v1/projects/{project}/messages:send"
    stale: list[str] = []
    sent = False

    for device in tokens:
        # `data` carries host/service/ts so tapping the notification deep-links
        # into the service detail screen at the moment the alert fired.
        payload = json.dumps(
            {
                "message": {
                    "token": device,
                    "notification": {"title": "ai-terminal", "body": message},
                    "data": {k: str(v) for k, v in data.items()},
                }
            }
        ).encode()
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(req, timeout=TIMEOUT)
            sent = True
        except urllib.error.HTTPError as exc:
            # 404/UNREGISTERED means the token rotated. Drop it; the app resyncs
            # the token list on its next connect.
            if exc.code in (400, 404):
                stale.append(device)
            else:
                print(f"fcm failed: {exc}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            print(f"fcm failed: {exc}", file=sys.stderr)

    if stale:
        cfg["tokens"] = [t for t in tokens if t not in stale]
        all_cfg = _load(CHANNELS)
        all_cfg["fcm"] = cfg
        try:
            with open(CHANNELS, "w") as fh:
                json.dump(all_cfg, fh, indent=2)
            os.chmod(CHANNELS, 0o600)
        except Exception:  # noqa: BLE001
            pass

    return sent


def main() -> int:
    message = sys.argv[1] if len(sys.argv) > 1 else "test"
    data = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    subject = data.get("subject", "ai-terminal alert")

    cfg = _load(CHANNELS)
    if not cfg:
        print("no channels configured", file=sys.stderr)
        return 1

    results = {
        "fcm": send_fcm(cfg.get("fcm", {}), message, data),
        "telegram": send_telegram(cfg.get("telegram", {}), message),
        "email": send_email(cfg.get("smtp", {}), message, subject),
    }
    print(json.dumps(results))
    return 0 if any(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
