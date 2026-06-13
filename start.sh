#!/bin/bash
# Start the CS 1.6 web server. Usage: ./start.sh
set -e
cd "$(dirname "$0")"

if ! docker info >/dev/null 2>&1; then
  echo "Starting Docker Desktop..."
  open -a Docker
  until docker info >/dev/null 2>&1; do sleep 2; done
fi

# First run: build the patched in-browser client (map picker + Esc fix).
if [ ! -f web/main.js ]; then
  echo "Preparing patched web client..."
  ./prepare-client.sh
fi

# First run: pull custom maps into valve.zip + the server (cs_mansion, ...).
if [ -f valve.zip ] && ! unzip -l valve.zip "cstrike/maps/cs_mansion.bsp" >/dev/null 2>&1; then
  echo "Adding custom maps..."
  ./add-maps.sh || echo "  (custom maps skipped — check your connection)"
fi

IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
if [ -z "$IP" ]; then
  echo "Could not detect LAN IP — is this machine connected to a network?"
  exit 1
fi

# write the host's current IP into the config (required by WebRTC)
sed -i '' -E "s/IP: .*/IP: $IP/" docker-compose.yml
docker compose up -d --force-recreate >/dev/null 2>&1

until docker logs cs16-web 2>&1 | grep -q "server started"; do sleep 1; done

URL="http://$IP:27016"
echo "$URL" | pbcopy
echo ""
echo "  ✅ Server is up!"
echo ""
echo "  Share this link with your team (already in the clipboard):"
echo ""
echo "      $URL"
echo ""
echo "  Stop the server: ./stop.sh"
