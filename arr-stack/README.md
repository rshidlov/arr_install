# Arr Stack: one-command media server setup

Runs Sonarr, Radarr, Prowlarr, qBittorrent, FlareSolverr, Plex, Seerr and a Homepage dashboard in Docker on a Mac, Linux or Windows machine. One script installs the container runtime, starts everything, connects the apps to each other through their APIs, and builds a dashboard with a link to every service.

Use it for content you have the rights to download.

## What you get

| Service | Port | What it does |
|---|---|---|
| Homepage | 3000 | Dashboard with links to everything, plus live stats for the arr apps |
| Seerr | 5055 | Browse and discover shows and movies, send requests to Sonarr/Radarr |
| Plex | 32400 | Media server |
| Sonarr | 8989 | TV manager |
| Radarr | 7878 | Movie manager |
| Prowlarr | 9696 | Indexer manager, syncs indexers to Sonarr and Radarr |
| qBittorrent | 8080 | Torrent client |
| FlareSolverr | 8191 | Helps Prowlarr with Cloudflare-protected indexers |

All services share one Docker network (`arr-net`) and reach each other by container name, for example `http://qbittorrent:8080`.

## Requirements

- A Mac (Apple Silicon or Intel), a Linux machine, or Windows 10/11.
- Internet access (the first run downloads a few GB of images).
- Enough disk space for your media. Use `DATA_DIR` to point at an external or larger drive.
- Linux: `sudo` access. Windows: permission to approve an Administrator prompt.

## Install

Get the files onto the machine, then run the script for your OS from inside the folder.

```bash
git clone <this-repo-url> arr-stack
cd arr-stack
```

### macOS

```bash
chmod +x setup.sh
./setup.sh
```

Installs [OrbStack](https://orbstack.dev) (via Homebrew if present, otherwise a direct download), starts it, and enables start at login. OrbStack may ask you to approve a few system prompts on first launch. If Docker does not come up in time, open OrbStack once by hand, finish its setup, and run the script again.

### Linux

```bash
chmod +x setup.sh
./setup.sh
```

Installs Docker Engine and the compose plugin using Docker's official install script (asks for `sudo`), adds your user to the `docker` group, and gives the Seerr config folder to UID 1000. Log out and back in afterwards so you can run `docker` without `sudo`.

### Windows

Open PowerShell in the folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

The script re-launches itself as Administrator, installs WSL2 and Docker Desktop (with `winget` if available), starts Docker Desktop, and continues. If Windows asks for a restart after installing WSL2, restart and run the script again.

Windows caveat: files on Windows drives that are mounted into containers are slower, and hardlinks and SQLite databases can be unreliable there. For best results, run `setup.sh` inside a WSL Ubuntu distro with Docker Desktop's WSL integration enabled, with this folder under `~/arr-stack`.

### Options

Set these before running the script.

| Variable | Effect |
|---|---|
| `DATA_DIR=/path/to/data` | Put torrents and media somewhere else. Mac/Linux: `DATA_DIR=/Volumes/Media/data ./setup.sh`. Windows: `$env:DATA_DIR = 'D:\data'` first. |
| `DISABLE_SLEEP=1` | Mac/Linux only. Stop the machine from sleeping (asks for `sudo`). |
| `PLEX_CLAIM=claim-xxxx` | Claim the Plex server to your account on first start. Get a token at https://plex.tv/claim (valid about 4 minutes). Put it in `.env` before the first run. |

### What the script does

1. Detects the OS and installs the container runtime (OrbStack, Docker Engine, or Docker Desktop).
2. Creates the folders and writes `.env` (user and group IDs, timezone, a generated qBittorrent password, the hosts the dashboard may be opened from).
3. Pulls the images and starts all containers.
4. Runs `wire.py` in a small helper container, which waits for each app to start, then:
   - sets the qBittorrent login and creates the `tv` and `movies` categories and the download path,
   - adds the root folders and the qBittorrent download client to Sonarr and Radarr,
   - adds the FlareSolverr proxy, Sonarr, Radarr and qBittorrent to Prowlarr,
   - adds the public indexers from `arr-config.json` (and your private ones, if you filled them in),
   - writes the Homepage dashboard config with a tile and live stats for each service.
5. Prints each service's address and a summary of the steps still left for you.

The script is safe to run again. Anything that already exists is skipped.

### Folder layout

Downloads and media live under one parent folder, so imports use hardlinks (instant, no duplicate files).

```
data/
  torrents/          qBittorrent downloads (tv/ and movies/ categories)
  media/
    tv/              Sonarr root folder, Plex TV library
    movies/          Radarr root folder, Plex Movies library
config/<app>/        each app's settings
```

## Manual steps after install

These need your own accounts or choices, so the script cannot do them.

1. **Open the dashboard.** The script prints its address, for example `http://<your-ip>:3000`.
2. **Plex.** Open `http://<your-ip>:32400/web`, sign in, and add two libraries:
   - TV Shows: `/data/media/tv`
   - Movies: `/data/media/movies`
3. **Seerr.** Open `http://<your-ip>:5055`, sign in with Plex, and in the setup wizard add:
   - Sonarr: host `sonarr`, port `8989`, the Sonarr API key, root folder `/data/media/tv`
   - Radarr: host `radarr`, port `7878`, the Radarr API key, root folder `/data/media/movies`

   The script prints both API keys at the end. They are also under **Settings > General** in each app.
4. **Sonarr, Radarr and Prowlarr logins.** Each asks you to set a username and password on your first visit. Do it.
5. **Optional: tell Plex to rescan on every import.** In Sonarr and Radarr go to **Settings > Connect > + > Plex Media Server**, host `plex`, port `32400`, click **Authenticate with Plex.tv**, and enable **On Import**, **On Upgrade** and **Update Library**.
6. **Optional: private trackers.** Put your logins in `arr-config.json` (see below) and run the script again.
7. **Optional: Plex on other devices.** In Plex, **Settings > Network > Custom server access URLs**, enter `http://<your-ip>:32400`. Plex runs with port mapping rather than host networking, so automatic discovery on the LAN may not work.
8. **Windows only:** allow the ports through Windows Firewall if you want to reach the apps from other devices.

Your qBittorrent username and password are in `.env` (`QBIT_USER`, `QBIT_PASS`).

## How to test that it works

### 1. Containers are running

```bash
docker compose ps
```

All eight services should show as running. If one keeps restarting, check it with `docker logs <name>`.

### 2. Dashboard

Open `http://<your-ip>:3000`. You should see tiles for all eight services. The Sonarr, Radarr, Prowlarr and qBittorrent tiles show live numbers. A tile showing an error usually means that app has not finished starting, or its login was changed.

### 3. The apps are connected

- **qBittorrent:** `http://<your-ip>:8080`. Log in with the `.env` credentials. The left sidebar should list `tv` and `movies` under Categories.
- **Sonarr and Radarr:** **Settings > Download Clients** shows qBittorrent. Click it and press **Test**; it should turn green. **Settings > Media Management** lists the root folder.
- **Prowlarr:** **Settings > Apps** shows Sonarr and Radarr. **Settings > Indexers** shows the FlareSolverr proxy. On the **Indexers** page, press **Test All Indexers**.
- **Indexers synced:** in Sonarr and Radarr, **Settings > Indexers** lists the Prowlarr indexers, each marked `(Prowlarr)`.

### 4. End-to-end test with a public-domain title

Use a title in the public domain so the test is clean, for example the 1968 film *Night of the Living Dead* or the 1922 film *Nosferatu*.

1. In Radarr, click **Add New**, search for the film, choose the `/data/media/movies` root folder, and add it with **Start search for missing movie** ticked. (Or use **Interactive Search** on the movie to pick a release yourself.)
2. Within a minute or two a download should appear in qBittorrent under the `movies` category.
3. When it finishes, Radarr imports it. The file should appear in `data/media/movies/`.
4. In Plex, the film should show up in the Movies library (rescan it if you skipped the optional Plex connection).

If nothing downloads, open Radarr's **Activity** page and the Prowlarr **History** page. A search that finds nothing usually means your indexers have no results for that title.

### 5. Hardlinks are working

After the import, the downloaded file and the imported file should be the same file on disk. Compare their inode numbers:

```bash
ls -li data/torrents/movies/*/* data/media/movies/*/*
```

Both lines show the same number in the first column. Or check the link count (2 means hardlinked):

```bash
stat -c %h <file>      # Linux
stat -f %l <file>      # macOS
```

If the numbers differ, the downloads and media are not on the same mounted folder. See Troubleshooting.

### 6. Seerr

In Seerr, search for a title and request it. It should appear in Sonarr or Radarr within a few seconds.

## Configuration

### arr-config.json

- `public_indexers`: indexers that need no account. `definition` is the indexer's name in Prowlarr (case, spaces and dots do not matter). Set `"flaresolverr": true` for an indexer behind Cloudflare.
- `private_indexers`: **put your private tracker logins here.** Copy the example from `_private_indexers_example` into this list, set the definition name, and fill in the fields that tracker needs (for example `username`, `password`, `apikey`, `cookie`, `passkey`). Field names must match what Prowlarr shows for that tracker.

Then run the script again. Indexer names that Prowlarr does not recognise are reported as warnings at the end of the run.

### .env

Written by the script on first run. See `.env.example` for what each value does. Do not commit `.env`.

### Dashboard

`config/homepage/services.yaml` is regenerated on every run while its first line is the generated-file marker. Delete that line if you want to edit the dashboard by hand and keep your changes.

## Updating

```bash
docker compose pull
docker compose up -d
```

Re-run the setup script after changing `arr-config.json`, or if the machine's IP address changed (it refreshes the dashboard links and allowed hosts).

## Troubleshooting

| Problem | Fix |
|---|---|
| Apps cannot reach each other ("connection refused") | Use the container name, for example `qbittorrent`, never `localhost` or the machine's IP. |
| Dashboard says "Host validation failed" | The address in your browser is not in `HOMEPAGE_ALLOWED_HOSTS` in `.env`. Add it (as `host:3000`) and run `docker compose up -d`, or re-run the script. |
| Wiring step printed warnings or an app was not ready | Wait a minute and re-run the setup script. It only does what is still missing. |
| qBittorrent says unauthorized | Use the credentials in `.env`. If you changed the password by hand, set `QBIT_PASS` in `.env` to match and re-run the script. |
| Import fails with a permissions error | Check `PUID` and `PGID` in `.env` match the user that owns the `data/` folder. |
| Files are copied instead of hardlinked | Downloads and media must be under the same mounted folder (`/data`). Do not mount `torrents` and `media` separately. On Windows, use the WSL setup. |
| A Prowlarr indexer fails with a Cloudflare error | Set `"flaresolverr": true` for it in `arr-config.json` and re-run, or add the `flaresolverr` tag to it in Prowlarr. |
| Seerr fails to start on Linux | Its config folder must be owned by UID 1000: `sudo chown -R 1000:1000 config/seerr`. |
| Everything stops after a reboot | Make sure Docker or OrbStack starts at login and the machine does not sleep (`DISABLE_SLEEP=1`). The containers use `restart: unless-stopped`. |

## Security notes

- The services are reachable by anyone on your network. Set a login on every app, and use [Tailscale](https://tailscale.com) or a reverse proxy rather than forwarding ports to the internet.
- `.env` holds the qBittorrent password and `config/` holds the apps' API keys. Neither is committed (see `.gitignore`).
- If you want torrent traffic tunneled through a VPN, route qBittorrent through a VPN container such as Gluetun. This stack does not do that for you.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Mac, Linux and WSL installer and runner |
| `setup.ps1` | Windows installer and runner |
| `docker-compose.yml` | The eight services on one network |
| `wire.py` | Connects the apps through their APIs and writes the dashboard config |
| `arr-config.json` | Indexer list, including the spot for private tracker logins |
| `.env.example` | Documents the values the setup script writes to `.env` |
