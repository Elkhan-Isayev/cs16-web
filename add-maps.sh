#!/bin/bash
# Wire custom (non-stock) maps into the server + clients.
#
# Stock CS 1.6 maps already live in valve.zip (rebuilt via SteamCMD, see README).
# Custom maps need to be (a) readable by the dedicated server and (b) present in
# valve.zip so browsers can load them. The .bsp files are bundled in ./custom-maps/
# (committed to the repo) and mounted into the server via docker-compose. This
# script makes sure each bundled map is also injected into valve.zip for clients.
#
# A map's .bsp is used straight from ./custom-maps/ if present; otherwise it is
# downloaded from the given URL as a fallback. Requires valve.zip to exist.
# After adding a NEW map, also list it in web/index.html's CUSTOM array.
set -e
cd "$(dirname "$0")"

if [ ! -f valve.zip ]; then echo "valve.zip missing — build it first (see README)."; exit 1; fi
mkdir -p custom-maps

# add_map <name> <fallback-zip-url>   (zip is expected to contain maps/<name>.bsp)
add_map () {
  local name="$1" url="$2" tmp
  tmp=$(mktemp -d)

  # 1) ensure we have the .bsp locally (prefer the bundled copy)
  if [ ! -f "custom-maps/$name.bsp" ]; then
    echo "Downloading $name (not bundled) ..."
    curl -fsSL -A "Mozilla/5.0" -o "$tmp/map.zip" "$url"
    unzip -o -j "$tmp/map.zip" "maps/$name.bsp" -d custom-maps >/dev/null
  fi
  # First byte must be 0x1e (GoldSrc BSP v30). `od` is POSIX (portable); `xxd`
  # isn't always installed on Linux.
  if [ "$(od -An -tx1 -N1 "custom-maps/$name.bsp" | tr -d ' \n')" != "1e" ]; then
    echo "✗ $name.bsp is not a GoldSrc v30 BSP"; rm -rf "$tmp"; exit 1
  fi

  # 2) ensure it's inside valve.zip for browser clients
  if unzip -l valve.zip "cstrike/maps/$name.bsp" >/dev/null 2>&1; then
    echo "✓ $name already in valve.zip"
  else
    local stage="$tmp/stage"; mkdir -p "$stage/cstrike/maps"
    cp "custom-maps/$name.bsp" "$stage/cstrike/maps/"
    ( cd "$stage" && zip -gq "$OLDPWD/valve.zip" "cstrike/maps/$name.bsp" )
    echo "✓ $name injected into valve.zip"
  fi
  rm -rf "$tmp"
}

# Bundled in ./custom-maps/. URL is only a fallback if the .bsp is ever missing.
add_map cs_mansion "https://ds-servers.com/maps/goldsrc/cstrike/cs_mansion.zip"

echo "Done. Restart the server to pick up new server-side maps: ./start.sh"
