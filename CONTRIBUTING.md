# Как помочь проекту

[English below](#contributing)

**Самое полезное - отчёт о совместимости.** Проверьте VPN Lens со своим VPN-клиентом и
[расскажите](https://github.com/wall-low/vpn-lens/issues/new?template=compatibility.yml),
что он показал. Кнопка «Скопировать отчёт» в меню собирает всё нужное; перед отправкой
уберите из отчёта адреса, которыми не хотите делиться.

**Ошибки и идеи** - через [issues](https://github.com/wall-low/vpn-lens/issues/new/choose).

**Код.** Перед pull request прогоните то же, что и CI:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
scripts/build-app.sh
swift test --package-path macos
scripts/check-localization.sh
```

Немного правил:

- Логику, которую можно проверить без сети и интерфейса, - в Rust-ядро или в
  `VPNLensLogic`, с тестом.
- Новый вердикт «мимо VPN» - только по замеру, а не по догадке.
- Новые строки интерфейса пишутся по-русски, английский перевод - в
  `macos/Resources/en.lproj/Localizable.strings`. Скрипт проверки перевода подскажет, чего
  не хватает.
- Как всё устроено - в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Contributing

**The most useful thing is a compatibility report.** Try VPN Lens with your VPN client and
[tell us](https://github.com/wall-low/vpn-lens/issues/new?template=compatibility.yml) what it
showed. The "Copy Report" menu item collects what's needed; remove any addresses you don't want
to share before posting.

**Bugs and ideas** go to [issues](https://github.com/wall-low/vpn-lens/issues/new/choose).

**Code.** Before a pull request, run what CI runs (see the commands above). Logic that can be
tested without the network and the UI belongs in the Rust core or in `VPNLensLogic`, with a test.
A new "bypasses VPN" verdict needs a measurement, not a guess. New UI strings are written in
Russian, with the English translation in `macos/Resources/en.lproj/Localizable.strings`.
Architecture notes: [docs/ARCHITECTURE.en.md](docs/ARCHITECTURE.en.md).
