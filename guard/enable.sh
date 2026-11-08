#!/usr/bin/env bash
# Instala/atualiza o plugin 00-fabroku-guard a partir deste diretorio (guard/).
# Rode como root:  sudo bash <caminho>/guard/enable.sh
# Idempotente: pode rodar apos cada plugin:update (que NAO roda o trigger install).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
PLUGINS="${PLUGIN_PATH:-/var/lib/dokku/plugins}"
NAME="00-fabroku-guard"
AVAIL="$PLUGINS/available/$NAME"
ENABLED="$PLUGINS/enabled/$NAME"

[[ -d "$PLUGINS/available" && -d "$PLUGINS/enabled" ]] || {
  echo "fabroku: $PLUGINS/{available,enabled} nao existe" >&2; exit 1; }

rm -rf "$AVAIL"
mkdir -p "$AVAIL"
cp "$SRC/core-post-extract" "$SRC/plugin.toml" "$AVAIL/"
chmod 755 "$AVAIL/core-post-extract"
chown -R "${DOKKU_SYSTEM_USER:-dokku}:${DOKKU_SYSTEM_GROUP:-dokku}" "$AVAIL"
ln -sfn "$AVAIL" "$ENABLED"
echo "00-fabroku-guard instalado:"
ls -la "$ENABLED/core-post-extract"
