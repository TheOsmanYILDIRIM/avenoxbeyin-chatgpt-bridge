#!/usr/bin/env sh
set -eu

REPO="https://github.com/TheOsmanYILDIRIM/avenoxbeyin-chatgpt-bridge.git"
ROOT="${AVENOX_BRIDGE_HOME:-$HOME/.local/share/avenox-brain-bridge}"
BIN="$HOME/.local/bin/avenox-bridge"

mkdir -p "$(dirname "$ROOT")" "$(dirname "$BIN")"

if [ -d "$ROOT/.git" ]; then
  echo "Bridge zaten yonetilen Git kurulumu: $ROOT"
elif [ -e "$ROOT" ]; then
  TMP="$ROOT.new.$$"
  BACKUP="$ROOT.backup-$(date +%Y%m%d%H%M%S)"
  rm -rf "$TMP"
  git clone --depth 1 "$REPO" "$TMP"
  (cd "$TMP" && npm test)

  mv "$ROOT" "$BACKUP"
  [ ! -f "$BACKUP/config.local.json" ] || cp "$BACKUP/config.local.json" "$TMP/config.local.json"
  [ ! -f "$BACKUP/.env" ] || cp "$BACKUP/.env" "$TMP/.env"
  mv "$TMP" "$ROOT"
  echo "Eski kurulum korundu: $BACKUP"
else
  git clone --depth 1 "$REPO" "$ROOT"
fi

cd "$ROOT"
npm test

cat > "$BIN" <<EOF
#!/bin/sh
exec node "$ROOT/src/cli.mjs" "\$@"
EOF
chmod +x "$BIN"

echo "Kurulum tamam: $BIN"
echo "Guncelleme: avenox-bridge update"
echo "Kontrol:    avenox-bridge update --check"
echo "Geri al:    avenox-bridge rollback"
