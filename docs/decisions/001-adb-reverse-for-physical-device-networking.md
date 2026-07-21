# 001 — Physical-device dev networking via `adb reverse`, not `10.0.2.2`
Date: 2026-06-26
Status: accepted
Thesis relevance: no

## Context
Development runs on a physical Samsung Galaxy S22, while the self-hosted Supabase stack (Docker) listens on the Windows laptop's loopback at `127.0.0.1:54321`. The phone and laptop are separate machines; on the phone, `127.0.0.1` refers to the phone itself. The widely-cited `10.0.2.2` alias reaches the host **only from the Android emulator** — it does not exist on physical hardware.

## Decision
Tunnel the phone's loopback to the laptop with `adb reverse tcp:54321 tcp:54321`; the app targets `http://127.0.0.1:54321`. Additionally allow plain HTTP in the **debug** manifest only (`android:usesCleartextTraffic="true"` in `android/app/src/debug/AndroidManifest.xml`).

## Rationale
Works over both USB and wireless adb; requires no LAN IP discovery, no firewall changes, and no rebinding of Supabase off loopback. One port covers REST, Auth, Storage and Realtime because Supabase routes everything through the API gateway on 54321. Release builds keep Android's HTTPS-only default.

## Alternatives rejected
- **`10.0.2.2`** — emulator-only alias; silently wrong for physical devices.
- **Laptop LAN IP** (e.g. `192.168.x.x`) — requires Supabase to bind non-loopback, Windows-firewall openings, and breaks whenever DHCP reassigns the address.
- **Emulator-only development** — avoids the issue but loses the real camera/GPS/touch behaviour a field app must be tested against.

## Consequences
The tunnel does **not** persist: it must be re-run after phone replug/reboot or `adb kill-server` (recurring "wireless tax"; first diagnostic for any `SocketException: Connection refused`). CLAUDE.md §7 was corrected accordingly.
