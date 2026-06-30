# Berryton

Drive an **Airton** air-conditioner (most likely a TCL clone) from **MQTT / Home Assistant**, using an
**ESP32 running Tasmota** wired to the A/C unit's internal serial bus, plus these Berry scripts.

The ESP talks the unit's serial protocol directly (no IR), exposes the A/C to Home Assistant over MQTT,
and can either let the A/C regulate on its own sensor or run its own hysteresis thermostat on an external
room-temperature source — **independently per heating and cooling mode**.

Original discussion: https://github.com/arendst/Tasmota/discussions/17328 (protocol work with pingus / pingus.org).

> First published project — the code is pragmatic rather than elegant, but it has been running daily for a
> long time. Comments and contributions welcome.

## Features

- Mode (auto / cool / dry / fan_only / heat / off), fan speed, louvre swing, temperature setpoint.
- **Per-mode regulation** (heat and cool configured independently): let the A/C regulate on its own sensor
  (with an offset), or have the ESP regulate with a hysteresis thermostat on a room temperature read from
  **MQTT** or polled over **HTTP**.
- **Home Assistant MQTT auto-discovery** — the climate entity appears by itself, no YAML to write.
- **Clean HA feedback**: HA always sees the *user's* setpoint (never the internal offset, never the 17/31 °C
  hysteresis extremes); the current temperature reported to HA is selectable.
- **IR-remote / external-change sync**: when someone uses the IR remote, the ESP reconciles its state from the
  A/C feedback frames instead of overwriting the change.
- A periodic **Wi-Fi heartbeat** keeps the Wi-Fi icon lit on the unit's display.
- A built-in **web config page** and a live **control panel** on the Tasmota main page.

## Hardware

- An ESP32 (developed on an **M5Stack Atom**) wired to the A/C unit's serial bus.
- Serial pins (configurable in `Berryton.be`): **RX = GPIO32, TX = GPIO26**, 9600 8N1.
- The unit drives the line at **5 V** → a bidirectional level shifter is recommended. (It has also run for over
  a year directly without one — at your own risk; opinions differ on ESP32 5 V tolerance.)

## Install / deploy

1. Flash Tasmota (ESP32 build) on the ESP.
2. Upload the `.be` files to the Tasmota filesystem (UFS) and an `autoexec.be` that loads them, e.g.:
   ```berry
   load("Berryton.be")          # core (required)
   load("berryton_config.be")   # web config page (optional)
   load("berryton_panel.be")    # main-page control panel (optional)
   load("berryton_emul.be")     # bench emulator, no real A/C (optional)
   ```
3. **Restart** the device (a full `Restart`, not just `BrRestart`) so Berry recompiles with a clean heap —
   the core file is large and a fragmented-heap reload can run out of memory.
4. On first boot, wait ~1-2 minutes for the script to recover the A/C state before the MQTT feedback is correct.

> Keep each `.be` file comfortably under ~30 KB — the on-device Berry compiler is memory-bound. Design notes
> live in `NOTES.md` and the observed serial frame layout in `FRAMES.md`.

## Configuration

All settings live in a single `BerrytonConfig` object, persisted to flash and editable from the **Berryton AC**
page in the Tasmota *Configuration* menu (provided by `berryton_config.be`).

### Per-mode regulation

For **each mode** (`heat_*` / `cool_*`) you choose a **source of regulation**:

| Source | Who regulates | Uses |
|--------|---------------|------|
| `ac`   | the A/C on its own sensor | `*_offset` (°C added in heat / subtracted in cool, to compensate the unit's high, enclosed sensor) |
| `mqtt` | the ESP (hysteresis) on a room temp from MQTT | `*_temp_topic`, `*_hyst` |
| `http` | the ESP (hysteresis) on a room temp polled over HTTP | `*_http_url`, `*_http_interval`, `*_hyst` |

In hysteresis (`mqtt`/`http`) mode the ESP forces the unit to 17 °C or 31 °C to run flat-out or coast. The
**offset and the 17/31 values never leak to Home Assistant** — HA always receives the user's real setpoint.

Other settings: MQTT command/feedback prefixes, beep, LCD display / ionizer / sleep / eco flags, HA device
name & unique id, HA discovery on/off, full vs simplified command set, the temperature reported to HA
(A/C sensor vs regulation source), debug logging, and a bench `serial_emulation` toggle.

## Home Assistant

The climate entity is created automatically via **MQTT auto-discovery** (`ha_discovery_enabled = 1`). Make sure
MQTT discovery is enabled in Home Assistant — nothing to add to `configuration.yaml`.

## MQTT topics

With the default prefixes `cmnd/Newclim/` and `tele/Newclim/`:

| Direction | Topic | Payload |
|-----------|-------|---------|
| command | `cmnd/Newclim/mode/set` · `fan/set` · `swing/set` · `temperature/set` | the value |
| feedback | `tele/Newclim/mode/get` · `fan/get` · `swing/get` | current value |
| feedback | `tele/Newclim/Actualtemp/get` | current temperature shown to HA |
| feedback | `tele/Newclim/Actualsetpoint/get` | the user setpoint |
| feedback | `tele/Newclim/remote/get` | IR-remote Wi-Fi state (`on`/`off`) |

## Repository layout

| File | Role |
|------|------|
| `Berryton.be` | core: serial protocol, regulation, MQTT, HA discovery, frame buffering |
| `berryton_config.be` | web config page (sections + radios) |
| `berryton_panel.be` | live control panel on the Tasmota main page |
| `berryton_emul.be` | bench emulator (fake A/C feedback frames, no real unit) |
| `tools/bcheck.sh` | compile-check `.be` files off-device (builds the standalone Berry interpreter) |
| `tools/tb.sh` | drive a test ESP32 over HTTP (eval, console, UFS upload) |
| `NOTES.md` | design notes & regulation glossary |
| `FRAMES.md` | observed Airton serial frame layout |

## Credits

Protocol work with **pingus** (pingus.org). Modbus CRC snippet from
https://github.com/peepshow-21/ns-flash/blob/master/berry/nxpanel.be.
