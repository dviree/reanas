# UGREEN NAS workbench

`install_rea_nas.sh` installs REA 6.4.0 with Ghidra 12.1.4 and OpenCode Web in
Docker on an x86_64 UGREEN NAS. It is a personal deployment script, not part of
the npm package. Run it as root:

```bash
sudo -i
bash install_rea_nas.sh
docker exec -it rea-workbench opencode auth login
```

Defaults: `REA_BASE=/volume2/docker/rea` (Ghidra, image build, compose, `.env`)
and `REA_DATA=/volume1/rea` (targets, workspace, persistent home and data).
Override either with an environment variable. The script downloads the official
Ghidra release and verifies its SHA-256, builds the image from a dedicated
`build/` context, and runs `rea doctor`, `rea setup --client opencode`, a web
login check, and a Ghidra smoke analysis.

The web UI binds to the Tailscale or LAN address recorded in `$REA_BASE/.env`.
If that address changes, edit `BIND_IP` there and run `docker compose up -d`.
