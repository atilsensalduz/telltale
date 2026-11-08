# Telltale

A read-only macOS menu bar app that tells you at a glance whether your network is down or degraded, and where:
Wi-Fi/router, ISP, DNS, or the web path. It keeps a history, lists outages, exports CSV, and can notify you.

- Native SwiftUI `MenuBarExtra`, no Dock icon, macOS 14+
- Unprivileged ICMP pings (router, 1.1.1.1, 8.8.8.8), a DNS query and an HTTPS request every 30 s
  (every second while something looks wrong)
- Diagnosis is a small state machine; the rules mirror `netwatch.py`, the original Python prototype
- History in a local SQLite database (raw 48 h, aggregates and events 90 days); nothing leaves your Mac
- No Location permission, no SSID, not sandboxed

## Layout

| Path | What |
| --- | --- |
| `TelltaleCore/` | Library (probing, diagnosis, storage, view models) and `telltale-cli`, with tests |
| `TelltaleApp/` | The menu bar app (SwiftUI) |
| `netwatch.py` | Reference implementation of the diagnosis rules; used by a test and `gen_rule_table.py` |

## Privacy

Telltale collects nothing and sends nothing to anyone. To measure your connection it pings your router, `1.1.1.1`
and `8.8.8.8`, sends a DNS query, and makes an HTTPS request to a fixed public host, the same as any browser
would. History stays in a local database at `~/Library/Application Support/Telltale/`; "Export CSV" writes only
where you choose. No analytics, no accounts, no Wi-Fi name (so no Location permission).

## Build and run

Needs Xcode (Swift 6 toolchain).

```sh
cd TelltaleCore && swift test            # or Scripts/test.sh with only the Command Line Tools
cd ../TelltaleApp && Scripts/bundle.sh   # builds build/Telltale.app (ad-hoc signed)
open build/Telltale.app
Scripts/install.sh                       # release build into ~/Applications
```

`TELLTALE_DEMO=1` runs the app against a scripted fake network. `Scripts/make_icon.swift` regenerates the icon.

The app is ad-hoc signed, not notarized, so build it yourself rather than downloading a prebuilt copy.

## License

[MIT](LICENSE)
