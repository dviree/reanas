#!/usr/bin/env bash
# REA 6.4.0 + Ghidra 12.1.4 + OpenCode Web on UGREEN (x86_64)
# Run as root on NAS. Idempotent; never reads arbitrary NAS media.
set -Eeuo pipefail
umask 027
trap 'echo "FEL: rad $LINENO avbrot installationen (kommando: $BASH_COMMAND)" >&2' ERR

BASE="${REA_BASE:-/volume2/docker/rea}"
DATA="${REA_DATA:-/volume1/rea}"
REA_VERSION=6.4.0
OPENCODE_VERSION=1.19.0
# Ghidra behover minuter for stora binarer pa en NAS. OpenCode avbryter annars
# varje MCP-anrop efter 5 s; klientens grans maste overstiga Ghidras startgrans.
GHIDRA_STARTUP_TIMEOUT_MS=1800000
MCP_TOOL_TIMEOUT_MS=2400000
GHIDRA_VERSION=12.1.4
GHIDRA_RELEASE_DATE=20260921
GHIDRA_SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
GHIDRA_DIRNAME="ghidra_${GHIDRA_VERSION}_PUBLIC"
GHIDRA_ZIP="${GHIDRA_DIRNAME}_${GHIDRA_RELEASE_DATE}.zip"
GHIDRA_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/${GHIDRA_ZIP}"
GHIDRA_ROOT="$BASE/ghidra/$GHIDRA_DIRNAME"

log() { printf '\n=== %s ===\n' "$*"; }
die() { echo "FEL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'Kor med sudo -i som root.'
[ "$(uname -m)" = x86_64 ] || die 'Skriptet ar gjort for x86_64. Arkitektur maste kontrolleras.'
command -v docker >/dev/null || die 'Docker saknas.'
docker info >/dev/null 2>&1 || die 'Docker-tjansten svarar inte.'
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 saknas.'
command -v curl >/dev/null || die 'curl saknas.'
command -v sha256sum >/dev/null || die 'sha256sum saknas.'
[ -d "$(dirname "$BASE")" ] || die "$(dirname "$BASE") finns inte. Justera REA_BASE."
[ -d "$(dirname "$DATA")" ] || die "$(dirname "$DATA") finns inte. Justera REA_DATA."

log 'Skapar enbart REA-mappar (inget befintligt innehall raderas)'
mkdir -p "$BASE/ghidra" "$BASE/downloads" "$BASE/build" "$BASE/config" "$BASE/home-ghidra" \
  "$DATA/targets" "$DATA/workspace" "$DATA/data/cache" "$DATA/data/share" "$DATA/data/state" \
  "$DATA/home/.config/opencode" "$DATA/home/.ghidra"
# Endast dedikerade katalogers agare; ingen rekursiv andring av befintliga malfiler.
for p in "$BASE/config" "$BASE/home-ghidra" "$DATA/targets" "$DATA/workspace" \
         "$DATA/data" "$DATA/data/cache" "$DATA/data/share" "$DATA/data/state" \
         "$DATA/home" "$DATA/home/.config" "$DATA/home/.config/opencode" "$DATA/home/.ghidra"; do
  chown 1000:1000 "$p"
done
rm -f "$BASE/installed.ok"

log "Installerar officiell Ghidra $GHIDRA_VERSION med SHA-256-kontroll"
# Packar upp och aterstaller Unix-rattigheter (inkl. exekveringsbitar) fran arkivet.
PY_UNZIP='
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for info in z.infolist():
        path = z.extract(info, sys.argv[2])
        mode = (info.external_attr >> 16) & 0o777
        if mode and not info.is_dir():
            os.chmod(path, mode)
'
if [ ! -f "$GHIDRA_ROOT/support/analyzeHeadless" ]; then
  ZIPFILE="$BASE/downloads/$GHIDRA_ZIP"
  if [ ! -f "$ZIPFILE" ] || ! printf '%s  %s\n' "$GHIDRA_SHA256" "$ZIPFILE" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$ZIPFILE"
    curl -fL --retry 4 --retry-delay 5 --connect-timeout 30 \
      -C - -o "$ZIPFILE.part" "$GHIDRA_URL"
    mv "$ZIPFILE.part" "$ZIPFILE"
  fi
  printf '%s  %s\n' "$GHIDRA_SHA256" "$ZIPFILE" | sha256sum -c - || {
    rm -f "$ZIPFILE"; die 'Ghidra SHA-256-kontroll misslyckades (filen raderad, kor skriptet igen).'; }
  STAGE="$BASE/ghidra/.extract"
  rm -rf "$STAGE" "$GHIDRA_ROOT"
  mkdir -p "$STAGE"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$ZIPFILE" -d "$STAGE"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "$PY_UNZIP" "$ZIPFILE" "$STAGE"
  else
    docker run --rm \
      -v "$BASE/downloads:/input:ro" -v "$STAGE:/output" \
      python:3.12-alpine python -c "$PY_UNZIP" "/input/$GHIDRA_ZIP" /output
  fi
  [ -f "$STAGE/$GHIDRA_DIRNAME/support/analyzeHeadless" ] || die 'Ghidra har inte packats upp korrekt.'
  mv "$STAGE/$GHIDRA_DIRNAME" "$GHIDRA_ROOT"
  rm -rf "$STAGE"
  rm -f "$ZIPFILE" "$ZIPFILE.part"
fi
# Containeranvandaren (uid 1000) ar inte agare; ge las/genomgang till alla och
# exekvering dar arkivet redan markerat filen som korbar.
chmod a+rx "$BASE" "$BASE/ghidra"
chmod -R a+rX "$GHIDRA_ROOT"

log "Skapar Docker-image: Node.js 24, Java 21, REA $REA_VERSION, OpenCode $OPENCODE_VERSION"
# Eget byggkontext: annars skickas hela $BASE (Ghidra, .env med losenord) till Docker-bygget.
cat > "$BASE/build/Dockerfile" <<DOCKERFILE
FROM eclipse-temurin:21-jdk-jammy AS jdk
FROM node:24-bookworm-slim
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk \\
    GHIDRA_INSTALL_DIR=/opt/ghidra/$GHIDRA_DIRNAME \\
    REA_ANALYSIS_PROVIDER=ghidra \\
    PATH=/opt/java/openjdk/bin:\$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \\
      ca-certificates curl git file python3 unzip procps && \\
    rm -rf /var/lib/apt/lists/*
RUN npm install --global rea-agents@$REA_VERSION opencode-ai@$OPENCODE_VERSION && \\
    npm cache clean --force && \\
    node --version && java -version && rea --version && opencode --version
USER node
WORKDIR /workspace
CMD ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]
DOCKERFILE
rm -f "$BASE/Dockerfile.full"

log 'Skapar OpenCode-REA MCP-konfiguration'
if [ ! -f "$BASE/config/opencode.json" ]; then
  cat > "$BASE/config/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "rea": {
      "type": "local",
      "command": ["rea", "mcp"],
      "enabled": true,
      "environment": {
        "GHIDRA_INSTALL_DIR": "/opt/ghidra/$GHIDRA_DIRNAME",
        "JAVA_HOME": "/opt/java/openjdk",
        "REA_ANALYSIS_PROVIDER": "ghidra"
      },
      "timeout": 30000
    }
  }
}
JSON
fi
chown 1000:1000 "$BASE/config/opencode.json"

log 'Valjer atkomst via Tailscale, annars lokalt NAS-IP'
if [ ! -f "$BASE/.env" ]; then
  BIND_IP=''
  if command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -n "$TS_IP" ] && command -v ip >/dev/null 2>&1 && \
       ip -4 addr show 2>/dev/null | grep -Fq "$TS_IP/"; then
      BIND_IP="$TS_IP"
    fi
  fi
  if [ -z "$BIND_IP" ] && command -v ip >/dev/null 2>&1; then
    BIND_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1 || true)"
  fi
  [ -n "$BIND_IP" ] || BIND_IP=127.0.0.1
  PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ -n "$PASSWORD" ] || die 'Kunde inte skapa losenord.'
  printf 'BIND_IP=%s\nOPENCODE_SERVER_PASSWORD=%s\n' "$BIND_IP" "$PASSWORD" > "$BASE/.env"
  chmod 600 "$BASE/.env"
  unset PASSWORD
fi

cat > "$BASE/compose.yml" <<YAML
name: rea-workbench
services:
  rea:
    build:
      context: ./build
    image: rea-workbench:$REA_VERSION
    container_name: rea-workbench
    restart: unless-stopped
    # Dockers standardnatverk: NAS-appar har ofta tagit slut pa adresspoolerna
    # sa att ett nytt projektnatverk inte kan skapas.
    network_mode: bridge
    ports:
      - "\${BIND_IP}:4096:4096"
    environment:
      HOME: /home/node
      JAVA_HOME: /opt/java/openjdk
      GHIDRA_INSTALL_DIR: /opt/ghidra/$GHIDRA_DIRNAME
      REA_ANALYSIS_PROVIDER: ghidra
      REA_GHIDRA_STARTUP_TIMEOUT_MS: "$GHIDRA_STARTUP_TIMEOUT_MS"
      XDG_CACHE_HOME: /data/cache
      XDG_DATA_HOME: /data/share
      XDG_STATE_HOME: /data/state
      OPENCODE_SERVER_USERNAME: opencode
      OPENCODE_SERVER_PASSWORD: \${OPENCODE_SERVER_PASSWORD}
    volumes:
      - ./ghidra/$GHIDRA_DIRNAME:/opt/ghidra/$GHIDRA_DIRNAME:ro
      - $DATA/home:/home/node:rw
      - ./config:/home/node/.config/opencode
      - ./home-ghidra:/home/node/.ghidra
      - $DATA/targets:/targets:ro
      - $DATA/workspace:/workspace:rw
      - $DATA/data:/data:rw
    working_dir: /workspace
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    pids_limit: 4096
    command: ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]
YAML

cd "$BASE"
docker compose config -q
log 'Bygger containern (kan ta en stund)'
docker compose build

log 'Kontrollerar REA + Ghidra'
DOCTOR_OK=0
if docker compose run --rm --no-deps rea rea doctor --provider ghidra --json > "$BASE/doctor.json" 2>&1; then
  DOCTOR_OK=1
  echo 'REA doctor utfort utan kommandofel.'
else
  echo 'VARNING: REA doctor rapporterade fel; se doctor.json.'
fi

log 'Installerar REA-skill for OpenCode'
SETUP_OK=0
if docker compose run --rm --no-deps rea rea setup --client opencode --yes --json > "$BASE/setup-report.json" 2>&1; then
  SETUP_OK=1
  echo 'REA agent-setup genomfort.'
else
  echo 'VARNING: skill-setup misslyckades; MCP-konfigurationen finns redan.'
fi

log 'Satter OpenCode:s MCP-tidsgrans for langa Ghidra-analyser'
# experimental.mcp_timeout lamnar REA:s egen serverpost orord; backup vid andring.
if docker compose run --rm --no-deps -e MCP_TOOL_TIMEOUT_MS="$MCP_TOOL_TIMEOUT_MS" rea node -e '
const fs = require("fs");
const file = "/home/node/.config/opencode/opencode.json";
const want = Number(process.env.MCP_TOOL_TIMEOUT_MS);
const config = JSON.parse(fs.readFileSync(file, "utf8"));
const current = config.experimental && config.experimental.mcp_timeout;
if (typeof current === "number" && current >= want) {
  console.log("Redan satt:", current, "ms");
} else {
  fs.copyFileSync(file, file + ".bak-" + Date.now());
  config.experimental = { ...(config.experimental || {}), mcp_timeout: want };
  fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
  console.log("mcp_timeout satt till", want, "ms");
}
'; then :; else
  echo 'VARNING: kunde inte satta mcp_timeout; langa Ghidra-anrop kan avbrytas efter 5 s.'
  SETUP_OK=0
fi

log 'Startar OpenCode Web + REA'
docker compose up -d
docker compose ps

log 'Kontrollerar webbserverns svar med intern auth (hemligheten visas inte)'
WEB_OK=0
for _ in $(seq 1 60); do
  if docker compose exec -T rea node -e '
const user = process.env.OPENCODE_SERVER_USERNAME || "opencode";
const password = process.env.OPENCODE_SERVER_PASSWORD || "";
const auth = "Basic " + Buffer.from(user + ":" + password).toString("base64");
fetch("http://127.0.0.1:4096/", {headers:{authorization:auth}})
.then(r => process.exit(r.ok ? 0 : 1))
.catch(() => process.exit(1));
' >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 3
done
[ "$WEB_OK" -eq 1 ] || die "OpenCode svarar inte. Kontrollera: cd $BASE && docker compose logs --tail=100 rea"

echo 'Webbserver OK.'

log 'Testar faktisk Ghidra-analys av systemets /usr/bin/true'
NATIVE_OK=0
if docker compose run --rm --no-deps rea rea analyze /usr/bin/true --provider ghidra --json > "$BASE/native-smoke.json" 2>&1; then
  NATIVE_OK=1
  echo 'Ghidra native smoke-test OK.'
else
  echo 'VARNING: native analys misslyckades. REA Web kan anvandas for andra analyser.'
  echo "Se $BASE/native-smoke.json och $BASE/doctor.json"
fi

BIND_IP="$(sed -n 's/^BIND_IP=//p' "$BASE/.env" | head -n 1)"
log 'Sammanfattning'
printf 'URL: http://%s:4096\nAnvandarnamn: opencode\n' "$BIND_IP"
printf 'Webblosenordet ligger lokalt (ej i logg): %s/.env\n' "$BASE"
printf 'Lagg analysfiler i: %s/targets (las-only i container, syns som /targets)\n' "$DATA"
printf 'Skrivbara projekt: %s/workspace\n' "$DATA"
printf 'AI-modell kopplas av dig efter installationen med: docker exec -it rea-workbench opencode auth login\n'

# Webbpanelen har svarat korrekt, och diagnostik finns vid eventuella delproblem.
touch "$BASE/installed.ok"
if [ "$DOCTOR_OK" -eq 1 ] && [ "$SETUP_OK" -eq 1 ] && [ "$NATIVE_OK" -eq 1 ]; then
  rm -f "$BASE/doctor.json" "$BASE/setup-report.json" "$BASE/native-smoke.json" "$BASE/install-full.log"
  echo 'Alla kontroller godkanda. Temporara loggar rensade.'
else
  echo 'En eller flera diagnostiska varningar; kontrollrapporterna finns kvar.'
fi
