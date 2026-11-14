#!/bin/bash

# get env variables
source "$(dirname "$0")/.env" || exit 1

# get credentials 48h (172800 secs). -f: fail on HTTP errors (401 etc.)
RESPONSE=$(curl -sf -X POST \
  "https://rtc.live.cloudflare.com/v1/turn/keys/${TURN_KEY_ID}/credentials/generate-ice-servers" \
  -H "Authorization: Bearer ${TURN_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"ttl": 172800}') || { echo "Cloudflare request failed"; exit 1; }

#echo "$RESPONSE"

# resolve username and credential (plain sed, tolerant of whitespace; no jq needed)
USERNAME=$(echo "$RESPONSE" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
CREDENTIAL=$(echo "$RESPONSE" | sed -n 's/.*"credential" *: *"\([^"]*\)".*/\1/p')

# check username and credential
if [ -z "$USERNAME" ] || [ -z "$CREDENTIAL" ]; then
  echo "Unable to get credentials from Cloudflare (response hidden)"
  exit 1
fi

# Talk reads static "username"/"password" per server (lib/Config.php getTurnSettings);
# "server" has NO scheme, "schemes" defaults to "turn"
TURN_CONFIG="[{\"server\":\"turn.cloudflare.com:3478\",\"username\":\"${USERNAME}\",\"password\":\"${CREDENTIAL}\",\"protocols\":\"udp,tcp\"}]"

# update Nextcloud AIO
docker exec --user www-data nextcloud-aio-nextcloud \
  php occ config:app:set spreed turn_servers --value="$TURN_CONFIG" >/dev/null || exit 1
echo "$(date -Is) TURN keys updated"
