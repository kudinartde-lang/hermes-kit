#!/usr/bin/env bash
# Собрать по отдельному архиву на каждую фичу: dist/<фича>.zip
# В архиве только эта фича (и то, без чего она не работает) + общие скрипты установки.
#
#   bash tools/build-feature-zips.sh [папка-вывода]
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$KIT/zips}"
CAT="$KIT/features/catalog.tsv"
mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
need() { awk -F'\t' -v id="$1" '$1==id {print $4}' "$CAT"; }
name() { awk -F'\t' -v id="$1" '$1==id {print $5}' "$CAT"; }

for F in $(grep -v '^#' "$CAT" | grep -v '^$' | cut -f1); do
  CHAIN="$F"; n="$(need "$F")"
  while [ -n "$n" ] && [ "$n" != "-" ]; do CHAIN="$CHAIN $n"; n="$(need "$n")"; done
  D="$TMP/hermes-$F"; rm -rf "$D"; mkdir -p "$D/features"
  (cd "$KIT" && git ls-files install.sh tools templates LICENSE* | grep -v 'tools/build-feature-zips.sh' \
     | while read -r f; do mkdir -p "$D/$(dirname "$f")"; cp "$f" "$D/$f"; done)
  { grep '^#' "$CAT"; for c in $CHAIN; do awk -F'\t' -v id="$c" '$1==id' "$CAT"; done; } > "$D/features/catalog.tsv"
  for c in $CHAIN; do
    (cd "$KIT" && git ls-files "features/$c" | while read -r f; do mkdir -p "$D/$(dirname "$f")"; cp "$f" "$D/$f"; done)
  done
  cat > "$D/ПРОЧТИ-МЕНЯ.md" <<EOF
# $(name "$F") - фича для помощника Hermes

Как поставить: отправь этот архив своему помощнику Hermes (в приложении или в Telegram) и напиши:

> Распакуй архив и выполни в папке: bash install.sh $F. Потом расскажи, что поставилось.

Больше ничего делать не нужно. Что умеет фича и что по желанию сделать потом - features/$F/README.md.
EOF
  rm -f "$OUT/hermes-$F.zip"
  (cd "$TMP" && python3 -m zipfile -c "$OUT/hermes-$F.zip" "hermes-$F")
  echo "  $OUT/hermes-$F.zip  ($(echo $CHAIN | wc -w) фич)"
done
