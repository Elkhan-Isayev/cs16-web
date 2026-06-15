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
  IMG=$(grep -E '^[[:space:]]*image:' docker-compose.yml | awk '{print $2}')
  echo "Building valve.zip from $IMG (one-time, ~400 MB)..."
  CID=$(docker create "$IMG") || { echo "✗ could not access server image — check your connection."; exit 1; }
  STAGE=$(mktemp -d)
  docker cp "$CID:/xashds/valve" "$STAGE/valve"
  docker cp "$CID:/xashds/cstrike" "$STAGE/cstrike"
  docker rm -f "$CID" >/dev/null 2>&1
  TARGET="$(pwd)/valve.zip"
  ( cd "$STAGE" && zip -rq "$TARGET" valve cstrike \
      -x "*.so" -x "*.dll" -x "*.exe" -x "*.dylib" -x "valve/dlls/*" -x "*/logs/*" )
  rm -rf "$STAGE"
  unzip -l valve.zip >/dev/null 2>&1 || { echo "✗ valve.zip build failed — see README."; exit 1; }
fi

# First run: pull custom maps into valve.zip + the server (cs_mansion, ...).
if [ -f valve.zip ] && ! unzip -l valve.zip "cstrike/maps/cs_mansion.bsp" >/dev/null 2>&1; then
  echo "Adding custom maps..."
  ./add-maps.sh || echo "  (custom maps skipped — check your connection)"
fi

IP=$(detect_ip)
if [ -z "$IP" ]; then
  echo "Could not detect LAN IP — is this machine connected to a network?"
  exit 1
fi

# write the host's current IP into the config (required by WebRTC). perl -i is
# used instead of `sed -i` because the in-place flag differs between BSD/macOS
# and GNU/Linux sed; perl behaves identically everywhere.
perl -i -pe "s/IP: .*/IP: $IP/" docker-compose.yml
docker compose up -d --force-recreate >/dev/null 2>&1

until docker logs cs16-web 2>&1 | grep -q "server started"; do sleep 1; done

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
