"""Uploads one build of one update channel to the image host.

Two channels exist and never share files:
  ios26  : the iOS 26+ app          -> latest-ios26.json (and latest.json, which installed iOS 26 builds read)
  compat : the iOS 15-18 app        -> latest-compat.json

Environment: IMGBED_TOKEN, CHANNEL (ios26|compat), BUILD (CI run number), VERSION, NOTES, IPA (path).
"""
import hashlib
import json
import os
import time
import urllib.parse
import urllib.request

HOST = "https://yun.nadev.xyz"
FOLDER = "moumusic"
TOKEN = os.environ["IMGBED_TOKEN"].replace("﻿", "").strip()
CHANNEL = os.environ["CHANNEL"]
BUILD = int(os.environ["BUILD"])
AUTH = {"Authorization": f"Bearer {TOKEN}", "User-Agent": "Mozilla/5.0 (compatible; Moumusic-CI/1.0)", "Accept": "*/*"}

CHANNELS = {
    "ios26": {"key": "full", "ipa": "Moumusic-full-ios26-unsigned", "manifests": ["latest-ios26.json", "latest.json"]},
    "compat": {"key": "compat", "ipa": "Moumusic-compat-ios15-18-unsigned", "manifests": ["latest-compat.json"]},
}
cfg = CHANNELS[CHANNEL]


def call(method, url, data=None, headers=None, retries=4):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=data, method=method, headers={**AUTH, **(headers or {})})
            with urllib.request.urlopen(req, timeout=300) as resp:
                return resp.read()
        except Exception as error:  # noqa: BLE001
            last = error
            if hasattr(error, "read"):
                try:
                    last = f"{error} body={error.read()[:300]!r}"
                except Exception:  # noqa: BLE001
                    pass
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
    print("upload", name, "->", src)
    if urllib.parse.unquote(src).split("/")[-1] != name:
        raise RuntimeError(f"host renamed {name} to {src}")
    return HOST + src


def upload_exact(path, name):
    """The host never overwrites by name and sometimes keeps the old file a moment after the delete, then stores
    the new one as "name(1)": remove both and try again until it is stored under the exact name."""
    for _ in range(6):
        delete(name)
        time.sleep(2)
        try:
            return upload(path, name)
        except RuntimeError as error:
            if "renamed" not in str(error):
                raise
            renamed = urllib.parse.unquote(str(error).rsplit(" to ", 1)[-1]).split("/")[-1]
            delete(renamed)
            time.sleep(4)
    raise RuntimeError(f"could not store {name} under its exact name")


def delete(name):
    try:
        reply = call("DELETE", f"{HOST}/api/manage/delete/{FOLDER}/{urllib.parse.quote(name)}", retries=1)
        print("delete", name, "->", reply[:160])
    except Exception as error:  # noqa: BLE001  (missing file is fine)
        print("delete", name, "failed:", error)


ipa_path = os.environ["IPA"]
ipa_name = f"{cfg['ipa']}-b{BUILD}.ipa"
entry = {
    "url": upload_exact(ipa_path, ipa_name),
    "size": os.path.getsize(ipa_path),
    "sha256": hashlib.sha256(open(ipa_path, "rb").read()).hexdigest(),
}

manifest = {
    "channel": CHANNEL,
    "version": os.environ["VERSION"],
    "build": BUILD,
    "notes": os.environ.get("NOTES", ""),
    "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    cfg["key"]: entry,
}
for manifest_name in cfg["manifests"]:
    with open(manifest_name, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, ensure_ascii=False, indent=2))
    # The host never overwrites by name: remove the old manifest first.
    upload_exact(manifest_name, manifest_name)
    check = None
    for _ in range(12):
        try:
            check = json.loads(call("GET", f"{HOST}/file/{FOLDER}/{manifest_name}?t={int(time.time())}", retries=1))
            if check.get("build") == BUILD:
                break
        except Exception:  # noqa: BLE001  (the host needs a moment after delete + upload)
            pass
        time.sleep(5)
    assert check and check["build"] == BUILD and check["channel"] == CHANNEL, check
    time.sleep(3)
    print("published", manifest_name, BUILD, entry["url"])

# Keep only the newest builds of this channel's IPA (the API token cannot list, so remove by name).
for old in range(max(1, BUILD - 6), BUILD - 1):
    delete(f"{cfg['ipa']}-b{old}.ipa")
