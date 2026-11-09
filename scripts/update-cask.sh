#!/bin/sh
# Обновляет cask в репозитории wall-low/homebrew-tap после выхода релиза.
#
#   scripts/update-cask.sh 0.1.0 ../homebrew-tap
#
# Контрольную сумму берёт из опубликованного релиза, а не из локальной сборки:
# cask должен совпадать с тем архивом, который скачают люди.
set -eu

VERSION=${1:?укажите версию, например 0.1.0}
TAP=${2:?укажите путь к клону wall-low/homebrew-tap}
cd "$(dirname "$0")/.."

SHA=$(gh release download "v$VERSION" --repo wall-low/vpn-lens --pattern "*.sha256" --output - | cut -d' ' -f1)
[ ${#SHA} -eq 64 ] || { echo "не удалось получить SHA-256 релиза v$VERSION" >&2; exit 1; }

mkdir -p "$TAP/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/vpn-lens.rb.in > "$TAP/Casks/vpn-lens.rb"
echo "$TAP/Casks/vpn-lens.rb: $VERSION, $SHA"
