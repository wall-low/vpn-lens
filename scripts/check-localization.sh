#!/bin/sh
# Проверяет, что у каждой строки интерфейса есть английский перевод.
# Ключи берёт сам компилятор Swift (-emit-localized-strings), поэтому подстановки
# вроде %@ и %lld совпадают с тем, что ищет приложение.
set -eu

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swift build -c release --package-path macos \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null

python3 -I - "$OUT" macos/Resources/en.lproj/Localizable.strings <<'PY'
import json, pathlib, re, subprocess, sys
keys = set()
for f in pathlib.Path(sys.argv[1]).glob("*.stringsdata"):
    for table in json.loads(f.read_text()).get("tables", {}).values():
        keys |= {e["key"] for e in table}
russian = {k for k in keys if re.search("[А-Яа-яЁё]", k)}
english = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", sys.argv[2]], check=True, capture_output=True).stdout)
missing = sorted(russian - english.keys())
stale = sorted(english.keys() - russian)
for k in missing:
    print("нет перевода:", k)
for k in stale:
    print("лишний перевод:", k)
print(f"строк: {len(russian)}, без перевода: {len(missing)}, лишних: {len(stale)}")
sys.exit(1 if missing else 0)
PY
