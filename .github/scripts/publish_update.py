"""Uploads the freshly built IPAs and the update manifest to the image host.

Environment: IMGBED_TOKEN (API token), BUILD (CI run number), VERSION (marketing version),
NOTES (release notes), FULL_IPA / COMPAT_IPA (paths). The app reads
https://yun.nadev.xyz/file/moumusic/latest.json and installs whatever it points at.
"""
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

HOST = "https://yun.nadev.xyz"
FOLDER = "moumusic"
TOKEN = os.environ["IMGBED_TOKEN"].replace("﻿", "").strip()
BUILD = int(os.environ["BUILD"])
AUTH = {"Authorization": f"Bearer {TOKEN}", "User-Agent": "Mozilla/5.0 (compatible; Moumusic-CI/1.0)", "Accept": "*/*"}


def call(method, url, data=None, headers=None, retries=4):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=data, method=method, headers={**AUTH, **(headers or {})})
            with urllib.request.urlopen(req, timeout=300) as resp:
                return resp.read()
        except Exception as error:  # noqa: BLE001
            last = error
            time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"{method} {url} failed: {last}")


def upload(path, name):
    boundary = "----moumusic" + hashlib.md5(name.encode()).hexdigest()
    body = open(path, "rb").read()
    payload = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + body + f"\r\n--{boundary}--\r\n".encode()
    query = urllib.parse.urlencode({"uploadFolder": FOLDER, "uploadNameType": "origin", "returnFormat": "default"})
    reply = json.loads(call("POST", f"{HOST}/upload?{query}", payload,
                            {"Content-Type": f"multipart/form-data; boundary={boundary}"}))
    src = reply[0]["src"]
    if urllib.parse.unquote(src).split("/")[-1] != name:
        raise RuntimeError(f"host renamed {name} to {src}")
    return HOST + src


def delete(name):
    try:
        call("DELETE", f"{HOST}/api/manage/delete/{FOLDER}/{urllib.parse.quote(name)}", retries=1)
    except Exception:  # noqa: BLE001  (missing file is fine)
        pass


def entry(path, name):
    return {"url": upload(path, name), "size": os.path.getsize(path),
            "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}


full_name = f"Moumusic-full-ios26-unsigned-b{BUILD}.ipa"
compat_name = f"Moumusic-compat-ios15-18-unsigned-b{BUILD}.ipa"
for name in (full_name, compat_name):
    delete(name)
full = entry(os.environ["FULL_IPA"], full_name)
compat = entry(os.environ["COMPAT_IPA"], compat_name)

manifest = {
    "version": os.environ["VERSION"],
    "build": BUILD,
    "notes": os.environ.get("NOTES", ""),
    "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "full": full,
    "compat": compat,
}
manifest_path = "latest.json"
open(manifest_path, "w", encoding="utf-8").write(json.dumps(manifest, ensure_ascii=False, indent=2))
# The host never overwrites by name: remove the old manifest first.
delete("latest.json")
upload(manifest_path, "latest.json")

# Verify what the app will actually read.
check = json.loads(call("GET", f"{HOST}/file/{FOLDER}/latest.json?t={int(time.time())}"))
assert check["build"] == BUILD, check
print("published build", BUILD, check["full"]["url"])

# Keep only the newest builds (the API token cannot list, so remove by name).
for old in range(max(1, BUILD - 6), BUILD - 1):
    delete(f"Moumusic-full-ios26-unsigned-b{old}.ipa")
    delete(f"Moumusic-compat-ios15-18-unsigned-b{old}.ipa")
