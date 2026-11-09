"""Restore CI signing inputs without printing passwords or keystore bytes."""
import base64
import os
from pathlib import Path

required = ["ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD"]
if any(not os.environ.get(key) for key in required):
    raise SystemExit("Android signing secrets are not configured")

android = Path("android")
keystore = android / "release-key.jks"
keystore.write_bytes(base64.b64decode(os.environ[required[0]], validate=True))
keystore.chmod(0o600)
password = os.environ[required[1]]
# Generated passwords use only URL-safe ASCII. No Java .properties escaping required.
if not password or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in password):
    raise SystemExit("Unsupported signing password characters")
properties = android / "key.properties"
properties.write_text(f"storeFile=release-key.jks\nstorePassword={password}\nkeyPassword={password}\nkeyAlias=ladno\n", encoding="utf-8")
properties.chmod(0o600)
print("Permanent Android signing key configured")
