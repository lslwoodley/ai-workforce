# Windows Host — Docker Setup Reference

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Windows | 10 build 19041+ or 11 | WSL2 requires this minimum |
| WSL2 | Latest | Required by Docker Desktop |
| Docker Desktop | 4.x+ | Includes Docker Engine + Compose |
| RAM | 8 GB minimum | 16 GB recommended (Paperclip + Hermes both need headroom) |
| Disk | 20 GB free | Docker images + volumes |

## Why Hermes runs in a container (not natively) on Windows

Hermes Agent does not support native Windows. Its install script targets Linux/macOS/WSL2. When you use Docker Desktop on Windows, containers run in a lightweight Linux VM inside WSL2 — so Hermes operates on Linux even though your host is Windows. This is fully transparent; you manage everything from PowerShell.

## Installing Docker Desktop

1. Download from https://www.docker.com/products/docker-desktop/
2. Run the installer — accept the UAC prompt
3. During install, select **"Use WSL 2 instead of Hyper-V"** (should be pre-selected on modern Windows)
4. After install, Docker Desktop launches automatically
5. Accept the service agreement and wait for the whale icon in the system tray to show **"Docker Desktop is running"**

If WSL2 isn't installed yet, Docker Desktop will prompt you to install it. Follow the prompt, reboot when asked, then restart Docker Desktop.

## File sharing (volume mounts)

Docker Desktop must be configured to share the drive where your project lives so it can mount volumes.

1. Open Docker Desktop → Settings → Resources → File Sharing
2. Click **+** and add the drive root (e.g. `C:\`) or the specific project folder
3. Click **Apply & Restart**

Without this, `docker compose up` will fail with a `Mounts denied` error.

## Running the setup script

Open **PowerShell** (not Command Prompt):

```powershell
# Allow the script to run (one-time, for this session)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# Navigate to the skill directory
cd "C:\Users\<you>\Documents\Claude\Projects\AI Management\skills\hermes-paperclip-setup"

# Run the setup
.\scripts\setup_windows.ps1
```

The script installs Docker Desktop if missing, configures WSL2, sets up file sharing, copies `.env`, builds images, and starts the stack.

## Path handling

Windows paths and Docker container paths are different. Docker Desktop translates automatically:

| Context | Path format |
|---------|-------------|
| Host (PowerShell) | `C:\Users\bruce\Documents\...` |
| In docker-compose.yml bind mounts | `C:\Users\bruce\Documents\...` (Docker Desktop translates) |
| Inside a container | `/hermes/sessions` (Linux paths only) |

In the `.env` file, use **Windows-style paths** for any `*_DIR` values that point to your host filesystem. Named volumes (like `hermes-sessions`) don't use host paths — Docker manages them internally and this distinction doesn't apply.

## Environment file location

```
skills\hermes-paperclip-setup\docker\.env
```

Edit with Notepad, VS Code, or any editor. Avoid editors that convert line endings to `\r\n` — Docker and the Linux containers inside will misread values. VS Code is safest (it defaults to LF).

## Accessing the stack

After `docker compose up`:

| Service | URL |
|---------|-----|
| Paperclip UI | http://localhost:3100 |
| MCP server | http://localhost:8765 |

Both are accessible from your Windows browser normally. No special WSL2 network config needed.

## Useful PowerShell commands

```powershell
# Check running containers
docker compose ps

# Follow all logs
docker compose logs -f

# Follow only Hermes logs
docker compose logs hermes-worker -f

# Shell into Hermes container (run hermes commands directly)
docker compose exec hermes-worker bash

# Stop everything
docker compose down

# Stop and wipe all data (fresh start)
docker compose down -v
```

## Common Windows-specific issues

**"Docker Desktop is starting" never resolves**
- Open Task Manager → check if `com.docker.backend.exe` is running
- If stuck, right-click the whale in the system tray → Restart Docker Desktop
- If that fails: restart WSL2 with `wsl --shutdown` in PowerShell, then restart Docker Desktop

**Volumes not mounting / permission errors**
- Docker Desktop → Settings → Resources → File Sharing → ensure the drive is listed
- After adding, click Apply & Restart

**`exec format error` in hermes-worker container**
- This means a Windows line ending crept into `entrypoint.sh`
- Fix: `docker compose exec hermes-worker bash -c "sed -i 's/\r//' /app/entrypoint.sh"` then `docker compose restart hermes-worker`

**Ports 3100 or 8765 already in use**
- Change `PAPERCLIP_PORT` or `MCP_SERVER_PORT` in `.env`
- Run `docker compose up -d` to apply

**WSL2 using too much RAM**
- Create `%UserProfile%\.wslconfig` with:
  ```ini
  [wsl2]
  memory=4GB
  processors=2
  ```
- Restart WSL2: `wsl --shutdown`

## Auto-start on Windows boot

Docker Desktop has a built-in option: Settings → General → **"Start Docker Desktop when you log in"**. With this on, the stack starts automatically when Docker Desktop starts. You can also set `docker compose up -d` to run on Docker Desktop startup via a Task Scheduler task or Docker Desktop's autostart compose feature.
