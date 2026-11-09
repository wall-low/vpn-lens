# How VPN Lens works

[Русский](ARCHITECTURE.md)

## Layers

```
crates/core                  Rust: per-process sockets, interfaces, proxy, DNS,
                             test requests, verdicts and check texts
crates/cli                   the vpnlens command-line tool
crates/uniffi-bindgen        Swift bindings generator
macos/Sources/VPNLensLogic   protection and kill switch logic without AppKit, with tests
macos/Sources/VPNLens        the app: menu, window, notifications, protection
```

The logic is written once in Rust; each OS gets its own native UI. The core keeps no state
and makes no UI decisions: it snapshots sockets, sends test requests and returns typed models
through [UniFFI](https://mozilla.github.io/uniffi-rs/).

The core needs no root and no special permissions:

- process sockets via `netstat2` (`proc_pidfdinfo`), the process tree via `sysinfo`;
- proxy, DNS, interface types and the network signature via SystemConfiguration;
- requests over the physical interface via `socket2` with `IP_BOUND_IF` and `rustls`;
- a small STUN client over UDP.

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

Only what a measurement confirms is marked red. Tunnel placeholder addresses (198.18.0.0/15),
the VPN client's local proxy and the client's own connections are not leaks. Verdicts are pure
functions of measurements in [`crates/core/src/report.rs`](../crates/core/src/report.rs), and
every row of the table is covered by a test.

Other checks:

- **UDP:** a STUN request, the way WebRTC does it. A common leak for proxy-only VPNs.
- **IPv6:** whether the physical interface has a public IPv6 and whether the VPN lets it out.
- **DNS:** where the system sends queries. Who finally receives them is shown by the external
  DNS test via bash.ws: VPN Lens opens unique subdomains and asks the service which resolvers
  came to resolve them.
- **Address per site:** VPN clients with domain rules route some sites differently. If test
  sites see different addresses, all of them are shown.
- **Crashed VPN client:** a system proxy is set, but nothing listens on its port.

The provider's address is remembered per network, keyed by the router signature macOS keeps
(`NetworkSignature`). A hash is stored, not the MAC address.

## App protection

The "tunnel is gone" event comes from `NWPathMonitor`, plus a fallback check every 5 seconds
while the list of protected apps is not empty. A check is the interface list and a probe
connection to the local proxy, about 0.7 ms.

VPN Lens knows the helper processes of protected apps in advance (it refreshes the list every
30 seconds), so it freezes the known processes at once and catches helpers that appeared since
the last refresh in a follow-up pass. In a test scenario where a process opened five
connections per second, freezing the known tree took 26 µs, and not a single connection got
through in three seconds. That is one measured scenario, not a guarantee: time also passes
between the drop and the system's event. Protection arms only after a VPN has been seen at least once; otherwise it would
freeze apps for someone without a VPN. If VPN Lens quits or crashes, frozen apps are released,
after a crash on the next launch, checking each process's start time so another process that
got the same pid isn't touched.

Real network-level blocking is possible with a Network Extension system extension
(`NEFilterDataProvider`, like LuLu), but that requires a paid Apple Developer account,
Developer ID signing and notarization.

Protection state transitions and the kill switch test result live in the `VPNLensLogic`
module without AppKit and are covered by Swift tests.

## macOS interface

The menu is SwiftUI inside a real `NSMenu`. The system treats the panel as a menu: in
full-screen mode the menu bar stays visible while it's open, and it closes on its own on an
outside click, Esc, Cmd+Tab or a Space change. Earlier versions used `MenuBarExtra` (the top of
the panel slid under the menu bar when its height changed) and a custom `NSPanel` (in
full-screen mode the menu bar hid right after the click). SwiftUI measures the content height
itself (`onGeometryChange`), because `NSHostingController` doesn't report size changes while a
menu is open.

The window is a `NavigationSplitView` in a regular `NSWindow`. While it's open the app has a
Dock icon; after closing it, VPN Lens lives only in the menu bar again.

## Languages

The UI is in Russian and English. By default it follows the system; Settings has a separate
language choice (like System Settings > Language & Region > Applications). Russian is the
development language and the fallback for any other language. The core builds check texts in
the requested language; UI strings are translated with `Localizable.strings`.
`scripts/check-localization.sh` takes the keys from the Swift compiler itself and checks that
every string has a translation.

## Building and debugging

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

What CI runs:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
swift test --package-path macos
scripts/check-localization.sh
```

App flags for debugging and screenshots:

- `--open` opens the menu at launch;
- `--window apps` opens the window on a section (`overview`, `apps`, `protection`, `checks`,
  `history`, `network`, `settings`);
- `--snapshot menu.png --app Safari` renders the menu to a file;
- `--demo` replaces real addresses with documentation ones (RFC 5737); every screenshot in the
  README was made this way;
- `--tour` together with `--window` shows the window's sections in turn, for the GIF.

A `vX.Y.Z` tag builds a universal archive and creates a draft release with notes from the
CHANGELOG. After the release is published, `scripts/update-cask.sh X.Y.Z` updates the Homebrew
cask.

The core builds on Windows and Linux, but there the proxy is read only from environment
variables, and there is no UI shell yet.
