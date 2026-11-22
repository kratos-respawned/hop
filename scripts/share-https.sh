#!/bin/sh
# Lets Share Files use HTTPS: gets a certificate for *.<name>, points that name at this Mac and renews weekly.
# Needs lego (brew install lego), a name hosted at desec.io (a subdomain handed over with NS records is enough), and a deSEC token saved with
#   security add-generic-password -s hop-dns -a dns -w
# Usage: scripts/share-https.sh hop.example.com
set -e
name=${1:?usage: share-https.sh <name hosted at desec.io>}
folder="$HOME/Library/Application Support/Hop/share"
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
DESEC_TOKEN=$(security find-generic-password -s hop-dns -w)
export DESEC_TOKEN

mkdir -p "$folder"
chmod 700 "$folder"

if [ ! -f "$folder/secure.json" ]; then
  curl -fsS -o /dev/null -X PATCH -H "Authorization: Token $DESEC_TOKEN" -H "Content-Type: application/json" \
    -d '[{"subname":"*","type":"A","ttl":3600,"records":["127.0.0.1"]}]' "https://desec.io/api/v1/domains/$name/rrsets/"
  jq -n --arg name "$name" '{name: $name}' > "$folder/secure.json"
  defaults delete dev.hop.launcher sharedAddress 2>/dev/null || true
fi

lego run --accept-tos --path "$folder/lego" --dns desec --dns.resolvers 1.1.1.1:53 --domains "*.$name" --pfx
find "$folder/lego" -name '*.pfx' -exec cp {} "$folder/certificate.p12" \;
chmod 600 "$folder/certificate.p12"

agent="$HOME/Library/LaunchAgents/dev.hop.share-https.plist"
if [ ! -f "$agent" ]; then
  cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.hop.share-https</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$(cd "$(dirname "$0")" && pwd)/share-https.sh</string><string>$name</string></array>
  <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>11</integer></dict>
  <key>StandardErrorPath</key><string>$folder/renew.log</string>
  <key>StandardOutPath</key><string>$folder/renew.log</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "$agent"
fi
