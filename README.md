# NO LONGER MAINTAINED

I'm not maintaining this anymore, I ended up ditching Authentik because it was just constant updating and breaking. Feel free to fork and use this at your own discretion!

---

# Authentik Manual Update Script

This script updates an **LXC-installed, source-built** instance of [Authentik](https://goauthentik.io) (originally set up using the now-deprecated Proxmox Helper Script).

It handles:

- 🔁 Pulling the latest release from GitHub  
- 🛟 Backing up PostgreSQL, `config.yml`, and `blueprints`  
- ⚙️ Rebuilding frontend and backend  
- 🛠️ Applying database migrations  
- ▶️ Restarting services

---

## 🚀 Quick Install & Usage

**Run this one-liner inside your Authentik LXC container:**

```bash
bash <(wget -qLO - https://raw.githubusercontent.com/straysignal/authentik-update/main/authentik-update.sh)
```

- This downloads the latest script and runs it directly.
- No need to manually save or chmod the script.

---

## 📦 Backups

Before updating, the script creates a backup in:

```
/root/authentik-backups/<timestamp>/
```

Includes:

- `db_backup.sql` (PostgreSQL dump)
- `/etc/authentik/config.yml`
- `/opt/authentik/blueprints/`

---

## ✅ Requirements

The script **automatically checks for required tools** and will prompt you to install any that are missing:

- `go`
- `node` + `npm`
- [`uv`](https://github.com/astral-sh/uv)
- `pg_dump` (from `postgresql-client`)

If a tool is missing, the script will ask:

```
Missing required commands: go uv
Attempt to install missing packages? [Y/n]:
```

If you confirm, it will attempt to install the missing packages using `apt-get` or `pip`.  
**You may need to run the script as root for installations to succeed.**

- Minimum **8–10 GB RAM** (or skip doc builds)

---

## ⚠️ Troubleshooting

If the container gets stuck (high CPU/RAM), SSH into the Proxmox host and run:

```bash
pct stop <vmid>
pct start <vmid>
```

---

## 🆕 Website Build Prompt

During the update, the script will **prompt you**:

```
Build website (documentation)? [Y/n]:
```

- Enter `n` or `N` to **skip building the website** (documentation).  
- Press `Enter` or type `y` to build it as usual.

> Skipping the website build can save time and memory, especially if you don't need the documentation site.

---

## 📝 Notes

- The script **removes and replaces** `/opt/authentik` with the latest release.
- All services (`authentik-server`, `authentik-worker`, `authentik-celery-beat`) are stopped and restarted.
- The current version is tracked in `/opt/Authentik_version.txt`.
- Backups are stored in `/root/authentik-backups/` with a timestamp.

---

🐺 Authentik, but DIY. Handle with care.
