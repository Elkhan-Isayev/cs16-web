#!/bin/bash
# Start the CS 1.6 web server. Usage: ./start.sh
# Works on macOS, Linux, and Windows via WSL2 / Git Bash (it's a bash script —
# it does not run in native cmd/PowerShell).
set -e
cd "$(dirname "$0")"

# --- portable helpers (macOS + Linux + WSL) ---

# Print this host's LAN IP. Tries macOS, then Linux (default-route src), then
# the generic `hostname -I`. WebRTC needs a routable address, not 127.0.0.1.
detect_ip() {
  local addr
  addr=$(ipconfig getifaddr en0 2>/dev/null) || addr=$(ipconfig getifaddr en1 2>/dev/null) || true
  if [ -z "$addr" ] && command -v ip >/dev/null 2>&1; then
    addr=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  if [ -z "$addr" ] && command -v hostname >/dev/null 2>&1; then
    addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$addr"
}

# Copy stdin to the clipboard using whatever the OS provides. Returns non-zero
# (without erroring) if no clipboard tool is available.
copy_clip() {
  if command -v pbcopy   >/dev/null 2>&1; then pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then wl-copy
  elif command -v xclip   >/dev/null 2>&1; then xclip -selection clipboard
  elif command -v xsel    >/dev/null 2>&1; then xsel --clipboard --input
  elif command -v clip.exe >/dev/null 2>&1; then clip.exe
  else return 1; fi
}

if ! docker info >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin) echo "Starting Docker Desktop..."; open -a Docker ;;
    *) echo "Docker isn't running. Start it (Docker Desktop, or 'sudo systemctl start docker'), then re-run ./start.sh"; exit 1 ;;
  esac
  until docker info >/dev/null 2>&1; do sleep 2; done
fi

# First run: build the patched in-browser client (map picker + Esc fix).
if [ ! -f web/main.js ]; then
  echo "Preparing patched web client..."
  ./prepare-client.sh
  CHANGED=1
fi

# First run: build the game assets (valve.zip) if absent. It is NOT in the repo
# (Valve's copyrighted content + ~400 MB > GitHub's file limit), so a fresh clone
# has no copy and must produce one. This MUST happen before `docker compose up`:
# otherwise Docker bind-mounts a path that doesn't exist and silently creates an
# empty ./valve.zip DIRECTORY, which the server then serves as a broken non-zip
# file — and every browser hangs forever on a pulsating logo (no error shown).
#
# We build it from the pinned server image, which already ships the game files
# under /xashds/{valve,cstrike} — so a clone needs only Docker, no SteamCMD.
#
# Drop the empty-directory trap left by any earlier run that hit exactly that.
[ -d valve.zip ] && rmdir valve.zip 2>/dev/null
if [ ! -f valve.zip ] || ! unzip -l valve.zip >/dev/null 2>&1; then
  [ -f valve.zip ] && { echo "valve.zip is present but not a valid zip — rebuilding."; rm -f valve.zip; }
  # Read the game image from the cs16-web service specifically (the proxy service
  # also has an image: line, so a blanket grep would grab both).
  IMG=$(awk '/^  cs16-web:/{f=1} f && /^    image:/{print $2; exit}' docker-compose.yml)
  [ -n "$IMG" ] || { echo "✗ could not read the cs16-web image from docker-compose.yml."; exit 1; }
  echo "Building valve.zip from $IMG (one-time, ~400 MB)..."
  CID=$(docker create "$IMG") || { echo "✗ could not access server image — check your connection."; exit 1; }
  STAGE=$(mktemp -d)
  docker cp "$CID:/xashds/valve" "$STAGE/valve"
  docker cp "$CID:/xashds/cstrike" "$STAGE/cstrike"
  docker rm -f "$CID" >/dev/null 2>&1
  TARGET="$(pwd)/valve.zip"
  # Trim Half-Life content CS 1.6 never loads (~45% smaller download + faster
  # in-browser unpack + less client RAM). Tier A: HL single-player/DM maps, intro
  # media, HL map overviews. Tier B: HL-only NPC voices + ambience. KEEP
  # valve/halflife.wad (CS maps share its textures) and every *.lst (the engine
  # crashes without cstrike/delta.lst). See docs/PERFORMANCE.md.
  ( cd "$STAGE" && zip -1 -rq "$TARGET" valve cstrike \
      -x "*.so" -x "*.dll" -x "*.exe" -x "*.dylib" -x "valve/dlls/*" -x "*/logs/*" \
      -x "valve/maps/*" -x "valve/media/*" -x "valve/overviews/*" \
      -x "valve/sound/scientist/*" -x "valve/sound/barney/*" -x "valve/sound/hgrunt/*" \
      -x "valve/sound/holo/*" -x "valve/sound/gman/*" -x "valve/sound/nihilanth/*" \
      -x "valve/sound/garg/*" -x "valve/sound/gonarch/*" -x "valve/sound/agrunt/*" \
      -x "valve/sound/bullchicken/*" -x "valve/sound/ichy/*" -x "valve/sound/tentacle/*" \
      -x "valve/sound/aslave/*" -x "valve/sound/zombie/*" -x "valve/sound/houndeye/*" \
      -x "valve/sound/headcrab/*" -x "valve/sound/ambience/*" -x "valve/sound/tride/*" )
  rm -rf "$STAGE"
  unzip -l valve.zip >/dev/null 2>&1 || { echo "✗ valve.zip build failed — see README."; exit 1; }
  CHANGED=1
fi

# First run: pull custom maps into valve.zip + the server (cs_mansion, ...).
if [ -f valve.zip ] && ! unzip -l valve.zip "cstrike/maps/cs_mansion.bsp" >/dev/null 2>&1; then
  echo "Adding custom maps..."
  ./add-maps.sh || echo "  (custom maps skipped — check your connection)"
  CHANGED=1
fi

IP=$(detect_ip)
if [ -z "$IP" ]; then
  echo "Could not detect LAN IP — is this machine connected to a network?"
  exit 1
fi
if ! printf '%s' "$IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  echo "Detected IP '$IP' is not a valid IPv4 address."; exit 1
fi

# Write the host's current IP into the config (required by WebRTC) — but only if
# it actually changed, so docker-compose.yml isn't left perpetually git-dirty.
# perl -i (not sed -i) so the in-place edit behaves the same on macOS/BSD and
# Linux; the regex is anchored to the IP: line and rewrites only its value.
if ! grep -qE "^[[:space:]]*IP:[[:space:]]*$IP([[:space:]]|\$)" docker-compose.yml; then
  perl -i -pe "s/^(\s*IP:\s*).*/\${1}$IP/" docker-compose.yml
  CHANGED=1
fi

# Recreate containers only when something actually changed (rebuilt assets,
# regenerated client, added maps, or a new IP); a plain `up -d` is a fast no-op
# otherwise. Don't swallow output, so a real failure is visible.
if ! docker compose up -d ${CHANGED:+--force-recreate}; then
  echo "✗ docker compose up failed."; exit 1
fi

# Wait for the dedicated server to be ready. Scope the log scan to THIS container
# start (--since) so a stale "server started" from a previous run can't make us
# exit early, and bound the wait so a crash/boot failure surfaces instead of
# hanging forever.
STARTED=$(docker inspect -f '{{.State.StartedAt}}' cs16-web 2>/dev/null)
[ -n "$STARTED" ] || { echo "✗ could not read cs16-web start time (is the container up?)."; exit 1; }
deadline=$((SECONDS + 120))
until docker logs cs16-web --since "$STARTED" 2>&1 | grep -q "server started"; do
  if [ "$(docker inspect -f '{{.State.Running}}' cs16-web 2>/dev/null)" != "true" ]; then
    echo "✗ cs16-web is not running — recent logs:"; docker logs --tail 30 cs16-web 2>&1; exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ timed out waiting for 'server started' — recent logs:"; docker logs --tail 30 cs16-web 2>&1; exit 1
  fi
  sleep 1
done

# The public link (port 27016) is served by the proxy, not cs16-web — so confirm
# the proxy is up and actually answering before telling the user it's ready.
if [ "$(docker inspect -f '{{.State.Running}}' cs16-proxy 2>/dev/null)" != "true" ]; then
  echo "✗ cs16-proxy is not running — recent logs:"; docker logs --tail 30 cs16-proxy 2>&1; exit 1
fi
if command -v curl >/dev/null 2>&1; then
  pdeadline=$((SECONDS + 30)) # own budget, so a slow server boot can't starve this
  until curl -fsS -o /dev/null "http://127.0.0.1:27016/"; do
    if [ "$SECONDS" -ge "$pdeadline" ]; then
      echo "✗ proxy is not answering on 27016 — recent logs:"; docker logs --tail 30 cs16-proxy 2>&1; exit 1
    fi
    sleep 1
  done
fi

URL="http://$IP:27016"
if printf '%s' "$URL" | copy_clip 2>/dev/null; then CLIP="  (already copied to your clipboard)"; else CLIP=""; fi
echo ""
echo "  ✅ Server is up!"
echo ""
echo "  Share this link with your team:$CLIP"
echo ""
echo "      $URL"
echo ""
echo "  Stop the server: ./stop.sh"
