<img src="docs/icon.png" width="96" align="right" alt="">

# VPN Lens

A macOS menu bar utility that shows how your VPN actually works: which apps go through
it and which go around it, what address sites see, and whether anything leaks over UDP,
IPv6 or DNS.

[Русский](README.md)

<img src="docs/menu-en.png" width="320" alt="VPN Lens menu"> <img src="docs/window-en.png" width="470" alt="VPN Lens window, Overview">

## Why

A VPN icon in the menu bar only tells you the client is connected. It won't tell you that
Telegram ignores the system proxy and connects directly, that your browser reveals your
real address over WebRTC, that IPv6 bypasses the tunnel, or that after sleep the VPN came
up a couple of seconds after apps went online. VPN Lens looks at every app's connections
and verifies all of this with real requests.

## Features

**Menu** - a short summary: the active app and whether it goes through the VPN, the address
sites see, what to do with the app if the VPN disconnects, and one line about all other apps.
The shield in the menu bar shows the overall result.

**Window** - the details:

- **Overview:** overall result, addresses sites see, the VPN client, check results.
- **Apps:** every app with network activity, search, status, each app's connections.
- **Protection:** apps that VPN Lens freezes or quits when the VPN disconnects.
- **Checks:** automatic checks, a kill switch test, an external DNS test.
- **History:** VPN connected and disconnected, address and network changes, leaks.
- **Network:** client, tunnels, proxies, interfaces, every test request.
- **Settings:** open at login, keyboard shortcut, online checks, notifications.

Notifications arrive when the VPN disconnects while apps keep working, when an app starts
bypassing the VPN, and when a check finds a leak.

## How VPN Lens decides that traffic bypasses the VPN

A connection over Wi-Fi proves nothing on its own: many VPN clients capture those sockets
too. So VPN Lens sends a test request bound to the physical interface (`IP_BOUND_IF`) and
looks at the address it went out with.

| Setup | A request over Wi-Fi went out as | An app with connections over Wi-Fi |
|---|---|---|
| No VPN | provider's address | "VPN is off" |
| Full tunnel that blocks bypass | the VPN's address | "Through VPN" |
| Split tunnel | provider's address | "Bypasses VPN" |
| System proxy only, no tunnel | provider's address | "Bypasses VPN" if it ignores the proxy |
| The request didn't get through | - | "Not verified", not "all good" |

Only what a measurement confirms is marked red. Tunnel placeholder addresses, the VPN
client's local proxy and the client's own connections are not leaks. All these scenarios
are covered by tests in [`crates/core/src/report.rs`](crates/core/src/report.rs).

Also checked:

- **UDP:** a STUN request, the way WebRTC does it. A common leak for proxy-only VPNs.
- **IPv6:** whether the physical interface has a public IPv6 and whether the VPN lets it out.
- **DNS:** where the system sends queries. Who finally receives them is shown by the
  external DNS test in Checks.
- **Address per site:** VPN clients with domain rules route some sites differently. If
  sites see different addresses, VPN Lens shows all of them.

## App protection

You can pick apps that must not go online without the VPN. When the VPN disconnects,
VPN Lens freezes them (`SIGSTOP`) together with all their helper processes and resumes
them when the VPN is back. You can quit them instead.

It is not a network filter. A few milliseconds pass between the tunnel going away and the
reaction, and something may slip out. On a test process that opened five connections per
second, freezing the whole tree took 26 µs, and not a single connection got through in three
seconds. Still, your VPN client's built-in kill switch is more reliable. A real network-level
filter is possible with a Network Extension system extension, which requires a paid Apple
Developer account.

Safari is not supported: its traffic goes through a shared WebKit system process.

## Install

Requires macOS 14 or later, Apple Silicon or Intel.

1. Download `VPN-Lens-*.zip` from [Releases](https://github.com/wall-low/vpn-lens/releases)
   and move "VPN Lens" to Applications.
2. The app is signed without an Apple Developer account and is not notarized, so macOS
   blocks it on first launch. Open System Settings > Privacy & Security and click
   "Open Anyway" next to VPN Lens.
3. On first launch a window explains what the app does. After that VPN Lens lives in the
   menu bar.

Open at login is in Settings. macOS may ask you to approve it in System Settings > General >
Login Items.

## Privacy

No telemetry. Nothing about your apps or connections leaves your Mac.

Automatically, at launch, when the network changes, and when you open the menu if more
than three minutes have passed:

| Where | Why | What the service sees |
|---|---|---|
| `cloudflare.com`, `ipify.org` | your external address, the normal way and through the proxy | your external address |
| `1.1.1.1` over Wi-Fi or Ethernet | whether traffic can bypass the tunnel | your address when bypassing |
| `stun.l.google.com`, `stun.cloudflare.com` | your UDP address, as WebRTC sees it | your UDP address |
| `2606:4700:4700::1111` | only if you have a public IPv6 | your IPv6 |
| `ip.nic.ru` | regional site, if enabled in Settings | your external address |

Only on demand: the external DNS test via `bash.ws` (the service sees your address and your
DNS servers) and the kill switch test.

One switch in Settings turns off all online checks.

Stored only on this Mac:

- settings, protected apps and provider addresses per network (a hash of the router
  signature, no MAC address) - `~/Library/Preferences/io.github.wall-low.vpnlens.plist`;
- event history - `~/Library/Application Support/VPN Lens/history.json`.

To remove everything, quit VPN Lens and delete these two files and the app.

## Limitations

- VPN Lens sees that an app talks to the VPN client's proxy, but not where the proxy takes it.
- Safari's traffic lives in the WebKit process: VPN Lens shows it but can't protect it.
- Sockets of root and other users' processes are not visible without privileges.
- Only TCP is listed. QUIC (UDP) connections are not shown yet.
- The provider's address is known only after the VPN has been off at least once on this network.
- The window badge polls window frames from CGWindowList four times a second and lags a
  little while dragging. It hides in full-screen apps.

## Building from source

You need Xcode 16 and Rust. Building for Intel and Apple Silicon at once needs
[rustup](https://rustup.rs): Homebrew's Rust only targets your own Mac's architecture.

```sh
scripts/build-app.sh --run          # build "build/VPN Lens.app" and launch it
scripts/build-app.sh --universal    # Apple Silicon + Intel
scripts/build-app.sh --zip          # plus a release archive with SHA-256
```

Command-line tool on the same core (English output with `LANG=en_US.UTF-8`):

```sh
cargo run -p vpnlens-cli              # full check
cargo run -p vpnlens-cli -- --offline # no internet requests
cargo run -p vpnlens-cli -- app chrome
cargo run -p vpnlens-cli -- report    # plain-text report
cargo run -p vpnlens-cli -- dns       # external DNS test
```

Tests and checks that CI runs:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
swift test --package-path macos
scripts/check-localization.sh       # every UI string has a translation
```

For debugging: `VPNLens --open` opens the menu at launch, `VPNLens --window apps` opens the
window on a section, `VPNLens --snapshot menu.png --app Safari` renders the menu to a file,
and `--demo` replaces real addresses with documentation ones (that's how the screenshots here were made).

## Architecture

```
crates/core            Rust: per-process sockets, interfaces, proxy, DNS,
                       test requests, verdicts and check texts
crates/cli             the vpnlens command-line tool
crates/uniffi-bindgen  Swift bindings generator
macos/Sources/VPNLensLogic   protection and kill switch logic without AppKit, with tests
macos/Sources/VPNLens        the app: menu, window, notifications, protection
```

The logic is written once in Rust; each OS gets its own native UI. The core keeps no state
and makes no UI decisions: it snapshots sockets, sends test requests and returns typed models
through [UniFFI](https://mozilla.github.io/uniffi-rs/). Verdicts ("through VPN", "bypasses VPN",
"not verified") are pure functions of measurements, so they are tested against setups the
developer's machine doesn't have.

On macOS the UI is SwiftUI inside a real `NSMenu`. The system treats the panel as a menu: in
full-screen mode the menu bar stays visible while it's open, and it closes on its own on an
outside click, Esc, Cmd+Tab or a Space change. SwiftUI measures the content height itself
(`onGeometryChange`), because `NSHostingController` doesn't report size changes while a menu
is open.

The core needs no root and no special permissions:

- process sockets via `netstat2` (`proc_pidfdinfo`), the process tree via `sysinfo`;
- proxy, DNS, interface types and the network signature via SystemConfiguration;
- requests over the physical interface via `socket2` with `IP_BOUND_IF` and `rustls`;
- a small STUN client over UDP.

The UI is in Russian and English and follows the system language. Russian is the development
language and the fallback for any other language. The core builds check texts in the requested
language; UI strings are translated with `Localizable.strings`.

The core builds on Windows and Linux, but there the proxy is read only from environment
variables, and there is no UI shell yet.

## License

[MIT](LICENSE)
