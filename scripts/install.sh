#!/data/data/com.termux/files/usr/bin/sh
set -eu

REPO="https://github.com/TheOsmanYILDIRIM/avenoxbeyin-chatgpt-bridge.git"
ROOT="${AVENOX_BRIDGE_HOME:-$HOME/.local/share/avenox-brain-bridge}"
BIN="$HOME/.local/bin/avenox-bridge"

mkdir -p "$(dirname "$ROOT")" "$(dirname "$BIN")"

if [ -d "$ROOT/.git" ]; then
  echo "Bridge zaten kurulu: $ROOT"
else
  if [ -e "$ROOT" ]; then
    echo "HATA: $ROOT var ama Git checkout degil. Config'i yedekleyip bu klasoru tasiyin." >&2
    exit 1
  fi
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
