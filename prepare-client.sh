#!/bin/bash
# Regenerate the patched in-browser client (web/main.js) from the pinned image.
#
# The upstream client is shipped inside the Docker image under a content-hashed
# filename (e.g. main-Sj92UznW.js). We serve a patched copy that exposes the
# engine instance on window.__xash so web/index.html's map picker can call it.
# This script re-extracts that bundle, re-applies the one-line patch, and keeps
# the hashed filename in sync across web/index.html and docker-compose.yml.
#
# Run it once after cloning, and again whenever you bump the image digest.
set -e
cd "$(dirname "$0")"

IMG=$(grep -E '^[[:space:]]*image:' docker-compose.yml | awk '{print $2}')
echo "Extracting web client from $IMG ..."

CID=$(docker create "$IMG")
trap 'docker rm -f "$CID" >/dev/null 2>&1' EXIT
TMP=$(mktemp -d)
docker cp "$CID:/xashds/public/assets" "$TMP/assets" >/dev/null

MAINJS=$(cd "$TMP/assets" && ls main-*.js | head -1)
if [ -z "$MAINJS" ]; then echo "Could not find main-*.js in image"; exit 1; fi
echo "Bundle: $MAINJS"

mkdir -p web
# The only patch: expose the engine instance as window.__xash for the map picker.
perl -0pe 's/=new Xash3DWebRTC\(/=window.__xash=new Xash3DWebRTC(/' "$TMP/assets/$MAINJS" > web/main.js
if ! grep -q "window.__xash=new Xash3DWebRTC(" web/main.js; then
  echo "Patch did not apply — upstream bundle changed; inspect manually."; exit 1
fi

# Keep the hashed filename consistent in the page and the compose mount.
sed -i '' -E "s#/assets/main-[A-Za-z0-9_-]+\.js#/assets/$MAINJS#g" web/index.html
sed -i '' -E "s#/xashds/public/assets/main-[A-Za-z0-9_-]+\.js#/xashds/public/assets/$MAINJS#g" docker-compose.yml

echo "Done. web/main.js regenerated and references updated to $MAINJS"
