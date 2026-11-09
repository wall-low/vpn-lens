#!/bin/sh
# Снимает GIF для README: окно VPN Lens в режиме --demo (адреса для документации)
# по очереди показывает разделы, скрипт делает снимки окна и склеивает их ffmpeg.
#
#   scripts/make-demo-gif.sh ru docs/demo.gif
#   scripts/make-demo-gif.sh en docs/demo-en.gif
#
# Нужны собранное приложение (scripts/build-app.sh) и ffmpeg. Снимок окна требует
# разрешения на запись экрана для терминала.
set -eu

LANG_CODE=${1:-ru}
OUT=${2:-docs/demo.gif}
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; pkill -x VPNLens 2>/dev/null || true' EXIT

# Номер окна VPN Lens: CGWindowList, а не AppleScript - так не нужен доступ к Accessibility.
cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where ((w[kCGWindowOwnerName as String] as? String) ?? "").hasPrefix("VPN") {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    if b["Width"]! >= 500 && b["Height"]! >= 300 { print(w[kCGWindowNumber as String]!); break }
}
SWIFT
swiftc -O -o "$WORK/winid" "$WORK/winid.swift"

pkill -x VPNLens 2>/dev/null || true
sleep 1
# Через open, как обычное приложение: у фонового процесса скрипта окно не появляется.
open -n "build/VPN Lens.app" --args -AppleLanguages "($LANG_CODE)" --demo --window overview --tour
sleep 3.5

# Тур: 4 с ожидания данных, затем 5 разделов по 2,5 с. Снимаем 2 кадра в секунду.
i=0
while [ $i -lt 30 ]; do
    W=$("$WORK/winid")
    [ -n "$W" ] && screencapture -x -o -l "$W" "$WORK/$(printf 'f%03d' $i).png"
    i=$((i + 1))
    sleep 0.5
done
pkill -x VPNLens 2>/dev/null || true

ffmpeg -loglevel error -y -framerate 2 -i "$WORK/f%03d.png" \
    -vf "scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    -loop 0 "$OUT"
echo "$OUT ($(du -h "$OUT" | cut -f1))"
