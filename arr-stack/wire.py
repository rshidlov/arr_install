#!/usr/bin/env python3
"""Wires up the arr stack through each app's HTTP API and generates the Homepage config.

Runs inside a python:3-alpine container on the arr-net Docker network (the setup scripts
start it), so it reaches everything by container name. Standard library only.
Safe to re-run: anything that already exists is skipped.

Inputs (environment): QBIT_USER, QBIT_PASS, QBIT_TEMP_PASS (optional), HOST_ADDR.
Other inputs: /work/arr-config.json and the apps' config.xml files under /work/config.
"""
import copy
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WORK = os.environ.get("WORK_DIR", "/work")
HOST_ADDR = os.environ.get("HOST_ADDR", "localhost")
QBIT_USER = os.environ.get("QBIT_USER", "admin")
QBIT_PASS = os.environ.get("QBIT_PASS", "")
QBIT_TEMP = os.environ.get("QBIT_TEMP_PASS", "")

# Addresses this script uses to reach the apps (override with URL_<NAME> for testing)
def own_url(name, port):
    return os.environ.get(f"URL_{name.upper()}", f"http://{name}:{port}")

# Addresses the apps use to reach each other (always container names)
INTERNAL = {
    "prowlarr": "http://prowlarr:9696",
    "sonarr": "http://sonarr:8989",
    "radarr": "http://radarr:7878",
    "qbittorrent": "http://qbittorrent:8080",
    "flaresolverr": "http://flaresolverr:8191/",
}

problems = []


def log(msg):
    print(f"==> {msg}", flush=True)


def warn(msg):
    print(f"!!  {msg}", flush=True)
    problems.append(msg)


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


# ---------------------------------------------------------------- HTTP helpers
def call(method, url, headers=None, body=None, timeout=60):
    """Return (status, parsed_json_or_text). Status 0 means the request itself failed."""
    h = dict(headers or {})
    data = None
    if isinstance(body, (dict, list)):
        data = json.dumps(body).encode()
        h.setdefault("Content-Type", "application/json")
    elif isinstance(body, str):
        data = body.encode()
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status, text = r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # connection refused, timeout, DNS...
        return 0, str(e)
    try:
        return status, json.loads(text)
    except ValueError:
        return status, text


def err_text(payload):
    """Short readable message from an *arr validation error."""
    if isinstance(payload, list):
        msgs = [p.get("errorMessage") or p.get("message") or str(p) for p in payload if isinstance(p, dict)]
        return "; ".join(msgs) or str(payload)
    if isinstance(payload, dict):
        return payload.get("message") or payload.get("errorMessage") or str(payload)
    return str(payload)[:300]


def read_api_key(app, timeout=240):
    path = os.path.join(WORK, "config", app, "config.xml")
    end = time.time() + timeout
    while time.time() < end:
        try:
            m = re.search(r"<ApiKey>([^<]+)</ApiKey>", open(path).read())
            if m:
                return m.group(1)
        except OSError:
            pass
        time.sleep(3)
    return None


class Arr:
    def __init__(self, name, port, api_version, key):
        self.name = name
        self.base = f"{own_url(name, port)}/api/{api_version}"
        self.headers = {"X-Api-Key": key}
        self.key = key

    def get(self, path):
        return call("GET", f"{self.base}/{path}", self.headers)

    def post(self, path, body):
        return call("POST", f"{self.base}/{path}", self.headers, body)

    def wait_ready(self, timeout=300):
        end = time.time() + timeout
        while time.time() < end:
            status, _ = self.get("system/status")
            if status == 200:
                return True
            time.sleep(4)
        return False

    def schema(self, kind, implementation):
        status, items = self.get(f"{kind}/schema")
        if status != 200 or not isinstance(items, list):
            return None
        for it in items:
            if norm(it.get("implementation")) == norm(implementation):
                return copy.deepcopy(it)
        return None

    def add(self, kind, item, label):
        """POST an item. Tries the normal (tested) save first; on failure explains and,
        if force=True items are acceptable, saves anyway."""
        status, res = self.post(kind, item)
        if status in (200, 201):
            log(f"{self.name}: added {label}")
            return True
        return err_text(res) if status else f"request failed: {res}"


def set_fields(item, values):
    for f in item.get("fields", []):
        if f.get("name") in values:
            f["value"] = values[f["name"]]
    return item


def add_forced(app, kind, item, label):
    """Add; if the connection test fails, save anyway (forceSave) and warn."""
    result = app.add(kind, item, label)
    if result is True:
        return True
    status, res = app.post(f"{kind}?forceSave=true", item)
    if status in (200, 201):
        warn(f"{app.name}: {label} was saved but its connection test failed ({result}). Check it in the UI.")
        return True
    warn(f"{app.name}: could not add {label}: {result}")
    return False


# ---------------------------------------------------------------- qBittorrent
def setup_qbittorrent():
    base = own_url("qbittorrent", 8080)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    ref = {"Referer": base, "Origin": base}

    def post(path, form):
        data = urllib.parse.urlencode(form).encode()
        req = urllib.request.Request(f"{base}{path}", data=data, headers=ref, method="POST")
        try:
            with opener.open(req, timeout=30) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:
            return 0, str(e)

    def login(user, pw):
        status, body = post("/api/v2/auth/login", {"username": user, "password": pw})
        return status == 200 and body.strip() == "Ok."

    log("qBittorrent: waiting for the web UI")
    end = time.time() + 180
    up = False
    while time.time() < end:
        status, _ = post("/api/v2/auth/login", {"username": "x", "password": "x"})
        if status:
            up = True
            break
        time.sleep(3)
    if not up:
        warn("qBittorrent did not answer; skipped its setup")
        return

    if login(QBIT_USER, QBIT_PASS):
        log("qBittorrent: login already set")
    elif QBIT_TEMP and login("admin", QBIT_TEMP):
        prefs = {"web_ui_username": QBIT_USER, "web_ui_password": QBIT_PASS}
        status, body = post("/api/v2/app/setPreferences", {"json": json.dumps(prefs)})
        if status == 200 and login(QBIT_USER, QBIT_PASS):
            log("qBittorrent: set the login from .env")
        else:
            warn("qBittorrent: could not set the password; use the temporary one from its logs")
            return
    else:
        warn("qBittorrent: could not log in (neither the .env password nor the first-run temporary one worked). "
             "Set the password in its web UI to match QBIT_PASS in .env, then re-run.")
        return

    post("/api/v2/app/setPreferences", {"json": json.dumps({"save_path": "/data/torrents/"})})
    for cat in ("tv", "movies"):
        form = {"category": cat, "savePath": f"/data/torrents/{cat}"}
        status, _ = post("/api/v2/torrents/createCategory", form)
        if status not in (200, 409):
            post("/api/v2/torrents/editCategory", form)
    log("qBittorrent: save path and tv/movies categories ready")


# ---------------------------------------------------------------- Sonarr / Radarr
def ensure_root_folder(app, path):
    status, existing = app.get("rootfolder")
    if status == 200 and any((r.get("path") or "").rstrip("/") == path.rstrip("/") for r in existing):
        return
    result = app.add("rootfolder", {"path": path}, f"root folder {path}")
    if result is not True:
        warn(f"{app.name}: could not add root folder {path}: {result}")


def ensure_qbit_client(app, category_field, category):
    status, existing = app.get("downloadclient")
    if status == 200 and any(norm(c.get("implementation")) == "qbittorrent" for c in existing):
        log(f"{app.name}: qBittorrent download client already present")
        return
    item = app.schema("downloadclient", "QBittorrent")
    if not item:
        warn(f"{app.name}: no qBittorrent schema found; add it by hand")
        return
    item.update({"name": "qBittorrent", "enable": True})
    set_fields(item, {
        "host": "qbittorrent", "port": 8080, "useSsl": False,
        "username": QBIT_USER, "password": QBIT_PASS, category_field: category,
    })
    add_forced(app, "downloadclient", item, "qBittorrent download client")


# ---------------------------------------------------------------- Prowlarr
def ensure_tag(p, label):
    status, tags = p.get("tag")
    if status == 200:
        for t in tags:
            if (t.get("label") or "").lower() == label:
                return t["id"]
    status, res = p.post("tag", {"label": label})
    return res.get("id") if status in (200, 201) and isinstance(res, dict) else None


def setup_prowlarr(p, sonarr_key, radarr_key, cfg):
    tag_id = ensure_tag(p, "flaresolverr")

    # FlareSolverr proxy
    status, proxies = p.get("indexerProxy")
    if status == 200 and any(norm(x.get("implementation")) == "flaresolverr" for x in proxies):
        log("Prowlarr: FlareSolverr proxy already present")
    else:
        item = p.schema("indexerProxy", "FlareSolverr")
        if item:
            item.update({"name": "FlareSolverr", "tags": [tag_id] if tag_id else []})
            set_fields(item, {"host": INTERNAL["flaresolverr"], "requestTimeout": 60})
            add_forced(p, "indexerProxy", item, "FlareSolverr proxy")
        else:
            warn("Prowlarr: no FlareSolverr schema found; add the proxy by hand")

    # Sonarr and Radarr as apps
    status, apps = p.get("applications")
    have = {norm(a.get("implementation")) for a in apps} if status == 200 else set()
    for impl, key in (("Sonarr", sonarr_key), ("Radarr", radarr_key)):
        if norm(impl) in have:
            log(f"Prowlarr: {impl} already connected")
            continue
        item = p.schema("applications", impl)
        if not item:
            warn(f"Prowlarr: no {impl} application schema found; connect it by hand")
            continue
        item.update({"name": impl, "syncLevel": "fullSync"})
        set_fields(item, {
            "prowlarrUrl": INTERNAL["prowlarr"],
            "baseUrl": INTERNAL[impl.lower()],
            "apiKey": key,
        })
        add_forced(p, "applications", item, f"{impl} application")

    # qBittorrent as a download client (for manual grabs from Prowlarr)
    status, clients = p.get("downloadclient")
    if status == 200 and any(norm(c.get("implementation")) == "qbittorrent" for c in clients):
        log("Prowlarr: qBittorrent download client already present")
    else:
        item = p.schema("downloadclient", "QBittorrent")
        if item:
            item.update({"name": "qBittorrent", "enable": True})
            set_fields(item, {
                "host": "qbittorrent", "port": 8080, "useSsl": False,
                "username": QBIT_USER, "password": QBIT_PASS, "category": "prowlarr",
            })
            add_forced(p, "downloadclient", item, "qBittorrent download client")

    add_indexers(p, tag_id, cfg)

    p.post("command", {"name": "ApplicationIndexerSync"})
    log("Prowlarr: asked it to sync indexers to Sonarr and Radarr")


def add_indexers(p, tag_id, cfg):
    wanted = [(e, False) for e in cfg.get("public_indexers", [])] + \
             [(e, True) for e in cfg.get("private_indexers", [])]
    if not wanted:
        return
    status, profiles = p.get("appProfile")
    profile_id = profiles[0]["id"] if status == 200 and profiles else 1
    status, schemas = p.get("indexer/schema")
    if status != 200 or not isinstance(schemas, list):
        warn("Prowlarr: could not read the indexer list; add indexers by hand")
        return
    status, existing = p.get("indexer")
    have = set()
    if status == 200:
        for i in existing:
            have.add(norm(i.get("definitionName")))
            have.add(norm(i.get("name")))

    for entry, is_private in wanted:
        name = entry.get("definition", "")
        if not name or name.startswith("your-tracker"):
            continue
        if norm(name) in have:
            log(f"Prowlarr: indexer {name} already present")
            continue
        match = next((s for s in schemas
                      if norm(s.get("definitionName")) == norm(name) or norm(s.get("name")) == norm(name)), None)
        if not match:
            warn(f"Prowlarr: indexer '{name}' not found in this Prowlarr version; check the name in arr-config.json")
            continue
        item = copy.deepcopy(match)
        item.update({"enable": True, "appProfileId": profile_id,
                     "tags": [tag_id] if entry.get("flaresolverr") and tag_id else []})
        set_fields(item, entry.get("fields", {}))
        result = p.add("indexer", item, f"indexer {item.get('name', name)}")
        if result is not True:
            kind = "private indexer" if is_private else "indexer"
            warn(f"Prowlarr: skipped {kind} {item.get('name', name)}: {result}")


# ---------------------------------------------------------------- Homepage
HOMEPAGE_MARKER = "# generated by the setup script - delete this line to keep your own edits"


def q(s):
    return json.dumps(s)  # valid YAML double-quoted string


def write_homepage(keys):
    d = os.path.join(WORK, "config", "homepage")
    os.makedirs(d, exist_ok=True)
    h = HOST_ADDR

    def tile(name, icon, port, desc, widget=None, path=""):
        lines = [f"    - {name}:",
                 f"        icon: {icon}",
                 f"        href: {q(f'http://{h}:{port}{path}')}",
                 f"        description: {q(desc)}"]
        if widget:
            lines.append("        widget:")
            lines += [f"          {k}: {q(v) if isinstance(v, str) else v}" for k, v in widget.items()]
        return "\n".join(lines)

    services = "\n".join([
        HOMEPAGE_MARKER,
        "- Media:",
        tile("Plex", "plex.png", 32400, "Watch your library", path="/web"),
        tile("Seerr", "jellyseerr.png", 5055, "Discover and request shows and movies"),
        "- Automation:",
        tile("Sonarr", "sonarr.png", 8989, "TV shows",
             {"type": "sonarr", "url": INTERNAL["sonarr"], "key": keys.get("sonarr", "")}),
        tile("Radarr", "radarr.png", 7878, "Movies",
             {"type": "radarr", "url": INTERNAL["radarr"], "key": keys.get("radarr", "")}),
        tile("Prowlarr", "prowlarr.png", 9696, "Indexers",
             {"type": "prowlarr", "url": INTERNAL["prowlarr"], "key": keys.get("prowlarr", "")}),
        "- Downloads:",
        tile("qBittorrent", "qbittorrent.png", 8080, "Torrent client",
             {"type": "qbittorrent", "url": INTERNAL["qbittorrent"],
              "username": QBIT_USER, "password": QBIT_PASS}),
        tile("FlareSolverr", "flaresolverr.png", 8191, "Cloudflare helper for indexers"),
        "",
    ])

    path = os.path.join(d, "services.yaml")
    existing = open(path).read() if os.path.exists(path) else ""
    if not existing or existing.startswith(HOMEPAGE_MARKER):
        open(path, "w").write(services)
        log("Homepage: wrote services.yaml")
    else:
        log("Homepage: services.yaml has your edits, leaving it alone")

    for fname, content in {
        "settings.yaml": ("title: Media Server\ntheme: dark\ncolor: slate\nheaderStyle: clean\n"
                          "layout:\n  Media:\n    style: row\n    columns: 2\n"
                          "  Automation:\n    style: row\n    columns: 3\n"
                          "  Downloads:\n    style: row\n    columns: 2\n"),
        "widgets.yaml": ("- resources:\n    cpu: true\n    memory: true\n    disk: /\n"
                         "- datetime:\n    text_size: xl\n    format:\n      timeStyle: short\n"),
    }.items():
        p = os.path.join(d, fname)
        if not os.path.exists(p):
            open(p, "w").write(content)
            log(f"Homepage: wrote {fname}")


# ---------------------------------------------------------------- main
def main():
    try:
        cfg = json.load(open(os.path.join(WORK, "arr-config.json")))
    except (OSError, ValueError) as e:
        warn(f"Could not read arr-config.json ({e}); using no extra indexers")
        cfg = {}

    log("Waiting for Sonarr, Radarr and Prowlarr to create their API keys")
    keys = {name: read_api_key(name) for name in ("sonarr", "radarr", "prowlarr")}
    missing = [n for n, k in keys.items() if not k]
    if missing:
        warn(f"No API key yet for: {', '.join(missing)}. Give them a minute, then re-run the setup script.")
        write_homepage({k: v for k, v in keys.items() if v})
        return 1

    setup_qbittorrent()

    sonarr = Arr("sonarr", 8989, "v3", keys["sonarr"])
    radarr = Arr("radarr", 7878, "v3", keys["radarr"])
    prowlarr = Arr("prowlarr", 9696, "v1", keys["prowlarr"])
    for app in (sonarr, radarr, prowlarr):
        if not app.wait_ready():
            warn(f"{app.name} did not become ready; skipped its setup")
    if not (sonarr.wait_ready(5) and radarr.wait_ready(5) and prowlarr.wait_ready(5)):
        write_homepage(keys)
        return 1

    ensure_root_folder(sonarr, "/data/media/tv")
    ensure_qbit_client(sonarr, "tvCategory", "tv")
    ensure_root_folder(radarr, "/data/media/movies")
    ensure_qbit_client(radarr, "movieCategory", "movies")
    setup_prowlarr(prowlarr, keys["sonarr"], keys["radarr"], cfg)
    write_homepage(keys)

    h = HOST_ADDR
    print(f"""
==============================================================
 Done. Open the dashboard:  http://{h}:3000

 qBittorrent login:  {QBIT_USER} / {QBIT_PASS}

 Still manual (needs your accounts):
  1. Plex     http://{h}:32400/web  - sign in, add libraries:
              TV /data/media/tv    Movies /data/media/movies
  2. Seerr    http://{h}:5055  - sign in with Plex, then add:
              Sonarr  host: sonarr  port: 8989  API key: {keys['sonarr']}
                      root folder: /data/media/tv
              Radarr  host: radarr  port: 7878  API key: {keys['radarr']}
                      root folder: /data/media/movies
  3. Sonarr / Radarr / Prowlarr ask you to set a login on first visit.
  4. Optional: Sonarr/Radarr Settings > Connect > Plex Media Server,
     so Plex rescans on every import.
  5. Private trackers: put your logins in arr-config.json, re-run the script.
==============================================================""", flush=True)
    return 0


if __name__ == "__main__":
    code = main()
    if problems:
        print("\nThings that need attention:")
        for p in problems:
            print(f"  - {p}")
    sys.exit(code)
