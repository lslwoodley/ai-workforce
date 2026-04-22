# Ubuntu Host — Docker Setup Reference

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Ubuntu | 20.04 LTS, 22.04 LTS, or 24.04 LTS | Other Debian-based distros likely work |
| RAM | 4 GB minimum | 8 GB recommended |
| Disk | 20 GB free | Images + volumes |
| User | Non-root with sudo | Do NOT run as root |

## Docker Engine vs Docker Desktop

On Ubuntu, use **Docker Engine** (the server daemon) — not Docker Desktop. Docker Desktop on Linux is a GUI wrapper that adds complexity without benefit for a server deployment. The setup script installs Docker Engine via the official apt repository.

## Running the setup script

```bash
# Make it executable
chmod +x scripts/setup_ubuntu.sh

# Run it
./scripts/setup_ubuntu.sh
```

The script handles: Docker Engine install, docker group membership, daemon startup, firewall rules, `.env` setup, image build, and an optional systemd service for auto-start on boot.

**Important:** If the script adds you to the docker group, it will exit and ask you to log out and back in. This is required for the group change to take effect. After logging back in, re-run the script — it will skip the steps already done and continue.

## Manual Docker Engine install

If you prefer to install manually (or the script doesn't work on your distro):

```bash
# Remove old Docker installs
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker's GPG key and repo
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine + Compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Add your user to docker group
sudo usermod -aG docker $USER
newgrp docker   # apply immediately (or log out/in)
```

## Firewall configuration (ufw)

If ufw is active, the setup script adds rules for ports 3100 and 8765 automatically. To add manually:

```bash
sudo ufw allow 3100/tcp comment "Paperclip UI"
sudo ufw allow 8765/tcp comment "Hermes MCP server"
sudo ufw reload
```

If you only want local access (not from other machines), don't open the firewall — `localhost` access always works regardless of ufw.

## Environment file

```bash
cp docker/.env.example docker/.env
nano docker/.env   # or vim, or any editor
```

Set at least one model API key:

```dotenv
OPENROUTER_API_KEY=sk-or-...    # gives access to 200+ models via one key
# OR
ANTHROPIC_API_KEY=sk-ant-...
# OR
OPENAI_API_KEY=sk-...
```

## Starting the stack

```bash
cd docker
docker compose up --build -d
```

Check it came up:

```bash
docker compose ps
docker compose logs -f
```

Paperclip UI: `http://<server-ip>:3100`

## Systemd service (auto-start on boot)

The setup script offers to install this automatically. Manual install:

```bash
DOCKER_DIR="$(pwd)/docker"

sudo tee /etc/systemd/system/ai-workforce.service > /dev/null <<EOF
[Unit]
Description=Hermes + Paperclip AI Workforce
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DOCKER_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ai-workforce.service
sudo systemctl start ai-workforce.service
```

Check status:

```bash
sudo systemctl status ai-workforce
journalctl -u ai-workforce -f
```

## Useful commands

```bash
# Status
docker compose ps
docker stats   # live CPU/RAM per container

# Logs
docker compose logs -f
docker compose logs paperclip -f --tail 100
docker compose logs hermes-worker -f

# Shell into a container
docker compose exec hermes-worker bash
docker compose exec paperclip sh

# Run hermes commands
docker compose exec hermes-worker hermes --version
docker compose exec hermes-worker hermes model

# Restart a service
docker compose restart hermes-worker

# Stop stack
docker compose down

# Wipe all data
docker compose down -v
```

## Backup and restore

```bash
# Backup all volumes
for vol in paperclip-data hermes-sessions hermes-skills; do
    docker run --rm \
        -v ${vol}:/data \
        -v $(pwd)/backups:/backup \
        alpine tar czf /backup/${vol}-$(date +%Y%m%d).tar.gz /data
done

# Restore a volume
docker run --rm \
    -v paperclip-data:/data \
    -v $(pwd)/backups:/backup \
    alpine tar xzf /backup/paperclip-data-20260422.tar.gz -C /
```

## Common Ubuntu-specific issues

**`Got permission denied while trying to connect to the Docker daemon socket`**
- User not in docker group: `sudo usermod -aG docker $USER` then log out/in

**Containers start but Paperclip UI not reachable from another machine**
- Check ufw: `sudo ufw status` — add `sudo ufw allow 3100/tcp` if needed
- Ensure `HOST=0.0.0.0` is set in the Paperclip service env (it is by default)

**`No space left on device` during build**
- Free disk space or prune unused Docker resources: `docker system prune -a`

**Hermes worker keeps restarting**
- No API key configured: check `.env` for `OPENROUTER_API_KEY` / `ANTHROPIC_API_KEY`
- Check logs: `docker compose logs hermes-worker --tail 50`

**Stack not starting after reboot (without systemd service)**
- Run `docker compose up -d` manually, or install the systemd service

## VPS-specific notes

For cloud VPS deployments (DigitalOcean, Hetzner, Linode, AWS EC2, etc.):

- The setup script works identically on a fresh Ubuntu VPS
- Minimum recommended spec: 2 vCPU, 4 GB RAM, 40 GB disk (per Paperclip's own docs)
- Point your domain at the VPS IP and put Nginx in front of port 3100 for HTTPS:

```nginx
server {
    listen 443 ssl;
    server_name paperclip.yourdomain.com;
    location / {
        proxy_pass http://localhost:3100;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

Use Certbot for free TLS: `sudo certbot --nginx -d paperclip.yourdomain.com`
