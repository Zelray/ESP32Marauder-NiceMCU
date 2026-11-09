# HANDOFF — ESP32 Marauder on the NiceMCU-32S-DEV 2.8" IPS

Written 2026-11-08. Fresh session: read this top to bottom before touching
anything. Everything below is either verified from the hardware itself or
quoted from a primary source; anything unverified is labelled as such.

---

## 1. Where it stands (status chart)

| Item | State |
|---|---|
| Fork created at `C:\Users\anon\anti-projects\MarauderNicePort` | Done |
| Upstream commit | `justcallmekoko/ESP32Marauder` master, cloned 2026-11-08, Marauder **v1.20.0** |
| Submodules initialised (`esp32_marauder/libraries/*`) | Done |
| New board target `MARAUDER_CYD_NICEMCU` | Written |
| CST816D capacitive touch driver | Written (`esp32_marauder/cst816d.h`) |
| ST7789 TFT setup header | Written (`User_Setup_cyd_nicemcu.h`) |
| Build script (`tools/build_nicemcu.ps1`) | Written |
| **Compiles cleanly** | **YES** — verified, see §7 |
| Flashed to the board | **YES** — merged image at 0x0, hash verified, 2026-11-08 |
| Boot verified | **YES (serial)** — boots to v1.20.0 menu, CST816D answers on I2C |
| Display verified by eye | **NO** — needs a human to look at the panel (§9) |
| Stock firmware backup | **YES** — 4 MB, see §8 |
| SD card support | Not yet (chip-select pin unknown) |
| RGB LED support | Not yet (three discrete pins, not a WS2812) |

**Do not flash anything until you have read §8 (rollback).**

---

## 2. Why this fork exists

Mike bought this board because it has a **pigtail antenna connector**, which
makes it a good Marauder carrier. Marauder has no target for it.

Context that explains some dead ends already explored (do not repeat them):

- **Wireless Wizard does not support this board and never has.** Their five CYD
  targets (`cyd28`, `cyd28_hat`, `cyd24`, `cyd24_awok`, `cyd35`) are all
  classic ESP32 with **ILI9341/ST7796 + resistive XPT2046 touch** (TFT_eSPI).
  Their only ESP32-C5 builds are the LilyGo T-Dongle C5 and the Seeed XIAO C5 —
  screenless nodes, not CYDs. A `cyd28_hat` manifest is an ESP32-classic image
  (chip ID `0` at header offset 12, bootloader at `0x1000`).
- **HaleHound** likewise ships only `esp32-cyd` and `esp32-cyd-hat` — classic
  ESP32.
- **Bruce** runs on a *different* C5 board (NM-CYD-C5, MAC
  `38:44:BE:24:8B:E0`), unrelated to this folder. Leave it alone.

---

## 3. Board identification (verified, not guessed)

| Property | Value | How it was established |
|---|---|---|
| USB bridge | CH340 on **COM20**, `USB\VID_1A86&PID_7523` | Windows PnP enumeration |
| Chip | **ESP32-D0WD-V3 rev v3.1**, 40 MHz crystal | `esptool flash-id` |
| MAC | `70:4b:ca:30:19:e4` | `esptool read-mac` |
| Flash | **4 MB** (Boya, `68/4016`) | `esptool flash-id` |
| Partition layout | nvs 0x9000, otadata 0xE000, app0 0x10000 (1.25 MB), app1 0x150000, spiffs 0x290000 (1.38 MB), coredump 0x3F0000 | read from 0x8000 |
| Board name | **NiceMCU-32S-DEV_2.8IPS** ("NiceMCU-01") | string literal inside the running app |
| Display | **ST7789 240×320**, SPI | string literals + LVGL panel init strings |
| Touch | **CST816D**, I2C | string literal `CST816D` + I2C touch init path |
| Factory firmware | "Factory UI" demo, built Mar 5 2024, IDF v4.4.7 | app descriptor at 0x10020 |
| Public source | <https://github.com/NiceMCU-01/NiceMCU-32S-DEV_2.8IPS> | repo discovered by search |

Because an ESP32 classic has no native USB, it appears as a **CH340** — this is
the single fastest way to tell it apart from Mike's two ESP32-**C5** boards,
which enumerate as Espressif native USB (`VID 303A`, `PID 1001`).

---

## 4. Pin map — the authoritative reference

Taken from NiceMCU's `include/nicemcu/board_config.h` and their factory UI
board map. **These are the values used in this port.**

### Display (ST7789, SPI)

| Signal | GPIO |
|---|---|
| MOSI | 13 |
| SCLK | 14 |
| CS | 15 |
| DC | 12 |
| RST | **2** (shared with touch) |
| Backlight | 25 |
| MISO | *not routed* (write-only panel) |

### Touch (CST816D, I2C)

| Signal | GPIO |
|---|---|
| SDA | 33 |
| SCL | 32 |
| INT | 36 |
| Address | `0x15` |
| Clock | 400 kHz |

### Everything else (from the factory UI, unused by this port so far)

| Thing | GPIO |
|---|---|
| RGB LED | 4 / 16 / 17 (three pins) |
| Key / button | 35 (input-only, **no internal pull-up**) |
| VBAT sense | 34 |
| Speaker | 26 |
| microSD | HSPI, card-detect 5, **chip-select unknown** |

---

## 5. What was changed, file by file

### `esp32_marauder/cst816d.h` (new)

CST816D driver. Exposes `cst816d_init()` and `cst816d_read_raw()` with the
**same return contract** as Marauder's FT6336 driver:

- `1` = finger down, `raw_x`/`raw_y` filled
- `0` = released
- `-1` = I2C transport error

Protocol (from NiceMCU's `src/nicemcu_display.cpp`):

```
write register 0x02, then read 5 bytes:
  [0] finger count      (0 == released)
  [1] X high nibble (& 0x0F)
  [2] X low byte
  [3] Y high nibble (& 0x0F)
  [4] Y low byte
x = ((p[1] & 0x0F) << 8) | p[2]
y = ((p[3] & 0x0F) << 8) | p[4]
```

### `esp32_marauder/Display.h`

- Added a compile-time guard: `MARAUDER_CYD_NICEMCU` requires `ST7789_DRIVER`.
- `HAS_CAP_TOUCH` now includes `cst816d.h` when `HAS_CST816D_TOUCH` is set,
  otherwise the original `ft6336.h`.

### `esp32_marauder/Display.cpp`

- Added two alias macros so the existing, already-tested capacitive-touch
  logic (rotation transforms, edge rejection, `last_touch_ms`) is reused
  unchanged:
  ```c
  #ifdef HAS_CST816D_TOUCH
    #define ft6336_init     cst816d_init
    #define ft6336_read_raw cst816d_read_raw
  #endif
  ```
  This is the whole reason the port is small: Marauder's cap-touch path above
  the driver is controller-agnostic.

### `esp32_marauder/configs.h`

Added, following the existing per-board pattern:

1. Board target line (`//#define MARAUDER_CYD_NICEMCU` in the list at the top).
2. `HARDWARE_NAME "NiceMCU-32S-DEV 2.8 IPS"`.
3. Entry in the `HAS_CSI_MOTION` capability list.
4. **Capability block** — notably:
   - `HAS_TOUCH`, `HAS_CAP_TOUCH`, **`HAS_CST816D_TOUCH`**
   - `HAS_BT`, `HAS_BT_REMOTE`, `HAS_BUTTONS`, `HAS_SCREEN`, `HAS_FULL_SCREEN`
   - `HAS_TEMP_SENSOR`, `HAS_CYD_PORTRAIT`, `HAS_NIMBLE_2`, **`HAS_IDF_3`**,
     `HAS_DIRECT_UPLOAD`
   - **`HAS_SD` + `USE_SD`** — required to link (see the note below), with
     `SD_CS -1` as a placeholder until the real chip-select is known.
   - `CTP_SDA 33`, `CTP_SCL 32`, `CTP_INT 36`, `CTP_RST -1`
   - `CAP_TOUCH_PANEL_WIDTH 240`, `CAP_TOUCH_PANEL_HEIGHT 320`
   - **Deliberately omitted**: `HAS_FLIPPER_LED`, `HAS_GPS`.

> **Two linking quirks found the hard way (do not "simplify" these away):**
>
> 1. **`HAS_SD` cannot be omitted.** `HAS_DIRECT_UPLOAD` code in
>    `CommandLine.cpp` (the `upload` command, ~line 700) and in
>    `MenuFunctions.cpp` (~lines 1899–1935, 4049+) dereferences `sd_obj`
>    with only `HAS_DIRECT_UPLOAD` around it, never `HAS_SD`. With `HAS_SD`
>    undefined the `sd_obj` definition in `esp32_marauder.ino` is compiled out
>    and the link fails with `undefined reference to 'sd_obj'`. Upstream never
>    hits this because every shipped board defines `HAS_SD`.
> 2. **`HAS_NIMBLE_2` and `HAS_IDF_3` must agree with the toolchain.**
>    `HAS_NIMBLE_2` means NimBLE-Arduino 2.x (const callbacks,
>    `setScanCallbacks`, `getManufacturerData()` → `std::vector`).
>    `HAS_IDF_3` means arduino-esp32 core 3.x (`WIFI_AUTH_WPA3_ENTERPRISE` and
>    friends). This board needs **both**, so the build must use core
>    **3.3.4** — not 2.0.11, which is only correct for the NimBLE-1 CYD
>    profiles.
5. Button block: `C_BTN 35`, `C_PULL false` (GPIO35 is input-only with no
   internal pull-up — an external pull-up is assumed to exist).
6. Screen geometry block, derived from the CYD **2USB** profile because that is
   the existing 240×320 **ST7789** CYD-class target. It defines both
   `HAS_ILI9341` and `HAS_ST7789`.
7. Keypad geometry block (same values as the other 240×320 CYDs).
8. `MARAUDER_TITLE_BYTES 13578`.

> **Important quirk:** `HAS_ILI9341` is used throughout Marauder as the
> "this board has a screen with touch" gate (see `Display.cpp`,
> `MenuFunctions.cpp`, `WiFiScan.cpp`). It does **not** mean the panel is
> literally an ILI9341 here. The actual driver comes from
> `User_Setup_cyd_nicemcu.h` (`ST7789_DRIVER`). Do not "clean this up".

### `User_Setup_cyd_nicemcu.h` (new)

Cloned from `User_Setup_cyd_2usb.h`, then:

- `ST7789_DRIVER` (already active in the template)
- `TFT_WIDTH 240`, `TFT_HEIGHT 320`
- `TFT_MOSI 13`, `TFT_SCLK 14`, `TFT_CS 15`
- `TFT_DC 12`, `TFT_RST 2`  ← **swapped vs the 2USB template**
- `TFT_MISO -1`
- `TFT_BL 25`
- `TOUCH_CS` intentionally **removed** (no XPT2046 on this board)
- `TFT_RGB_ORDER TFT_BGR` kept from the template.
- **`TFT_INVERSION_ON` — required.** Verified on hardware 2026-11-08: with the
  template's `TFT_INVERSION_OFF` the panel rendered photo-negative. If a
  future rebuild looks wrong again, check this line first.

### `User_Setup_Select.h`

Added a commented `//#include <User_Setup_cyd_nicemcu.h>` line for parity with
the other boards. Not required for the build (see §6).

### `tools/build_nicemcu.ps1` (new)

Reproduces Marauder's CI build locally. See §6.

---

## 6. How to build

```powershell
pwsh -NoProfile -File C:\Users\anon\anti-projects\MarauderNicePort\tools\build_nicemcu.ps1
```

The script:

1. Installs `arduino-cli` into `%USERPROFILE%\bin` if missing.
2. Installs **esp32 core 3.3.4**. This is the version upstream CI pairs with
   NimBLE-2 / `HAS_IDF_3` profiles. Core 2.0.11 is only right for the older
   NimBLE-1 CYD targets and fails here with `WIFI_AUTH_WPA3_ENTERPRISE`.
3. Clones the exact library versions from `.github/workflows/build_parallel.yml`
   into `.build-libs\`, and copies `User_Setup_cyd_nicemcu.h` over
   `TFT_eSPI\User_Setup.h`.
4. Compiles with target `MARAUDER_CYD_NICEMCU`:
   ```
   FQBN:  esp32:esp32:d32:PartitionScheme=no_ota
   CPP:   -DMARAUDER_CYD_NICEMCU
   Link:  -Wl,-zmuldefs
   ```
5. Writes artefacts to `build_nicemcu\`.

> **Partition scheme: `no_ota`, not `min_spiffs`.** With core 3.3.4 + NimBLE
> 2.3.8 the app links to **1,970,727 bytes**, which is ~4.6 KB over the
> `min_spiffs` app slot (1,966,080). The `d32` board only offers
> `default` / `minimal` / `no_ota` / `min_spiffs` (there is no `huge_app`), so
> `no_ota` (2,097,152 app, 1.875 MB SPIFFS) is the only scheme with room.
> Consequence: **no OTA partition**, so firmware updates are USB- or
> SD-based. FQBN and upload must use the same scheme.

> **`-Wl,-zmuldefs` is mandatory.** Upstream CI gets it by editing
> `platform.txt` before building:
> `sed -i 's/compiler.c.elf.extra_flags=/compiler.c.elf.extra_flags=-Wl,-zmuldefs /'`
> (see `.github/workflows/build_parallel.yml` ~line 245). Without it the link
> fails on duplicate symbols — `connectionPending` / `operationInProgress`
> (defined in a header) and `ieee80211_raw_frame_sanity_check` (defined in
> `WiFiScan.cpp:126`, colliding with the copy in the precompiled IDF WiFi
> library). This is not a bug in the port; it is how Marauder is designed to
> build.

Add `-Clean` to wipe `.build-libs` and the build output. Add `-Port COM20` to
upload straight after a successful build.

**Why not PlatformIO?** Upstream does not build the firmware with PlatformIO
(the root `platformio.ini` only defines a `native` unit-test env). Reproducing
the arduino-cli invocation keeps library versions identical to CI, which
removes an entire class of confusing failures.

---

## 7. Build result — VERIFIED 2026-11-08

The port compiles and links cleanly.

| Item | Value |
|---|---|
| Result | **SUCCESS** (exit 0) |
| Toolchain | arduino-cli 1.5.1, **esp32 core 3.3.4** |
| NimBLE-Arduino | **2.3.8** |
| TFT_eSPI | 2.5.34 (Bodmer) + `User_Setup_cyd_nicemcu.h` |
| FQBN | `esp32:esp32:d32:PartitionScheme=no_ota` |
| Compile flags | `-DMARAUDER_CYD_NICEMCU`, `-Wl,-zmuldefs` |
| Sketch size | **1,970,727 bytes (93%)** of 2,097,152 |
| Static RAM | **78,768 bytes (24%)** — 248,912 bytes free |

Artefacts in `build_nicemcu\`:

| File | Size | SHA256 |
|---|---|---|
| `esp32_marauder.ino.merged.bin` | 4,194,304 | `35B603AC49F77CECCEC534E754093A1FB22A407BC7CE5723F3BD136A8BB1E8A9` |
| `esp32_marauder.ino.bin` | 1,970,288 | `B998AA8412A1D810C0EBB7D40D4759C675957F8FF6CA8FC38698C0702BAAF2B7` |
| `esp32_marauder.ino.bootloader.bin` | 23,664 | `38977B0FEBFDB370DC12CD7E4B48AEC60480005F6FA9D29E84BADDDD72CD01D2` |
| `esp32_marauder.ino.partitions.bin` | 3,072 | `6A88D59601A83A16A19A08114B59D338324B8DEC267D8B43E5D61AD56EC92102` |

`esp32_marauder.ino.merged.bin` is the whole 4 MB flash image and can be
written straight to offset `0x0` — convenient, and the same total size as the
board's flash.

> **A clean build does NOT mean the hardware works.** Nothing has been flashed
> yet. The display, touch, and orientation are all still unverified on real
> silicon — see §9.

### If a later build fails

1. **Library version drift** — re-check every `ref` in
   `tools/build_nicemcu.ps1` against `.github/workflows/build_parallel.yml`.
2. **NimBLE vs core mismatch** — `HAS_NIMBLE_2` needs NimBLE 2.x; `HAS_IDF_3`
   needs core 3.x. Pair them or you get ~40 type errors.
3. **"text section exceeds available space"** — you are back on a smaller
   partition scheme; use `no_ota`.

---

## 8. Rollback (read before flashing)

The board's **original factory firmware exists nowhere online**. A full 4 MB
read was taken before any write:

```
C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin
4,194,304 bytes
SHA256 DBCC6CCDA97A4587DD01BA59E1906277CDE61EAF1E7E01D73B22150F79E22981
```

Restore it with:

```powershell
python -m esptool -p COM20 -b 460800 write-flash 0x0 `
  "C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin"
```

Verify the hash **before** writing anything:

```powershell
(Get-FileHash "C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin" -Algorithm SHA256).Hash
```

---

## 9. Flashing and first-boot verification

Flash the build output with the same FQBN used to compile it so the partition
layout matches:

```powershell
# easiest path — arduino-cli handles bootloader + partition table + app
arduino-cli upload -p COM20 --fqbn esp32:esp32:d32:PartitionScheme=no_ota `
  --input-dir C:\Users\anon\anti-projects\MarauderNicePort\build_nicemcu `
  C:\Users\anon\anti-projects\MarauderNicePort\esp32_marauder
```

### Boot log actually captured (2026-11-08, COM20, 115200)

```
ets Jul 29 2019 12:21:46
rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)
...
ESP-IDF version is: v5.5.1-710-g8410210c9a
[Touch] CST816D probe on SDA 33 / SCL 32: ok      <-- our driver found the part
Settings ... (loaded from NVS)
Failed to mount SD Card                            <-- expected: SD_CS is -1
SD Card NOT Supported
Finished settings nodes
Changing to main menu...
      ESP32 Marauder
           v1.20.0
       By: justcallmekoko
>
```

One harmless warning appears right after boot:

```
E (637) gpio: gpio_pulldown_en(116): GPIO number error (input-only pad ...)
```

That is the button definition touching GPIO35, which is input-only and cannot
have an internal pull-down. It does not stop the boot. If it is worth cleaning
up, the fix is in the button block in `configs.h` (`HAS_C` / `C_BTN 35`) —
verify what actually calls `gpio_pulldown_en` before changing anything.

### Hardware behaviours verified on this board (2026-11-08)

These are non-obvious and cost several flash cycles each. Do not regress them.

1. **Panel inversion is ON.** `TFT_INVERSION_ON` in `User_Setup_cyd_nicemcu.h`.
   With `OFF` the whole UI renders photo-negative.
2. **Touch must be initialised AFTER `tft.init()`.** The panel and the CST816D
   share reset on GPIO2. Marauder's original order (touch first) meant
   `tft.init()` reset the touch controller immediately afterwards: the boot
   probe printed `ok`, then no taps ever registered. Moved in `Display.cpp`.
3. **The backlight is ACTIVE-LOW.** GPIO25 drives a P-channel MOSFET (AO3401)
   high-side switch. Measured: pin LOW = full, pin HIGH = dim, PWM duty 128 =
   half. `BL_SET` and `BL_PREVIEW` therefore write `255 - duty` for this board,
   and `TFT_BACKLIGHT_ON LOW` is defined so TFT_eSPI's init leaves it lit.
   Symptom if this is ever undone: the brightness menu reads 100% while the
   panel sits at its dimmest, and dimming appears to do nothing.
4. **The on-board key on GPIO35 must stay disabled.** GPIO35 is input-only with
   no internal pull-up/pull-down. `Switches(C_BTN, 1000, false)` asks for a
   pull-down the pad cannot provide, producing `gpio_pulldown_en` errors, a
   floating pin, phantom `justPressed()` events, and — because that handler
   sets `headless_mode = true` and calls `backlightOff()` — the screen
   "settling darker" a few seconds after boot. `HAS_BUTTONS` is off.
5. **Brightness ceiling is hardware.** Driving GPIO25 LOW is the maximum this
   circuit allows; there is no brighter state available in firmware.

### Checklist

1. **Serial log at 115200** — expect a Marauder splash and:
   ```
   [Touch] CST816D probe on SDA 33 / SCL 32: ok
   ```
   `NO ACK` means the I2C bus or address is wrong — stop and re-check §4.
2. **Splash renders and the menu appears.** If the screen is blank, see the
   display knobs below.
3. **Tap something.** If taps land in the wrong place, see touch knobs below.
4. **Menu → Device Info** should report `NiceMCU-32S-DEV 2.8 IPS`.

### Tuning knobs (in `User_Setup_cyd_nicemcu.h` unless noted)

| Symptom | Fix |
|---|---|
| Colours are wrong (red/blue swapped) | swap `TFT_RGB_ORDER TFT_BGR` ↔ `TFT_RGB`
| Picture is a photo-negative | **VERIFIED — this board needs `TFT_INVERSION_ON`.** Set 2026-11-08; with `TFT_INVERSION_OFF` the menu renders as a photo-negative |
| Blank screen, backlight on | confirm `ST7789_DRIVER`, `TFT_WIDTH 240`, `TFT_HEIGHT 320`; try lowering `SPI_FREQUENCY` to 20000000 |
| Backlight never comes on | confirm `TFT_BL 25`; check `backlightOn()` in `esp32_marauder.ino` |
| Taps offset / mirrored | the rotation transform lives in `Display::updateTouch()` (`Display.cpp`), **not** in `cst816d.h`. `HAS_CYD_PORTRAIT` and `SCREEN_ORIENTATION` in `configs.h` are the first knobs |
| Taps ignored entirely | check the `[Touch] CST816D probe` line; then whether `CTP_INT` gating is involved |

---

## 10. Known gaps and next steps

1. **SD card (stubbed, not working).** `HAS_SD`/`USE_SD` are defined so the
   build links, but `SD_CS` is `-1`, so mounting fails and SD features are
   inert. The chip-select is not in NiceMCU's public `board_config.h`; it must
   be read off `docs/NiceMCU-32S-2.8IPS_原理图V2.0.pdf` (the schematic text was
   downloaded and flattened, but the TF-card net names did not survive text
   extraction cleanly — open the PDF itself, not a text dump). The factory UI
   string `{"Bus", "HSPI"}` suggests the card shares the display SPI bus
   (MOSI 13 / CLK 14); only the CS is missing. Once known: set `SD_CS`, and if
   the card has its own SPI pins, also set `SD_MISO`/`SD_MOSI`/`SD_SCK` and
   `HAS_SEPARATE_SD` — mirror the CYD_MICRO block in `configs.h`.
2. **RGB LED.** Factory UI says GPIO 4/16/17 — three pins, so it is probably
   not a WS2812. Either drive it as three GPIOs or skip it. Do **not** define
   `HAS_NEOPIXEL_LED` expecting a single data line.
3. **Speaker (26) / VBAT (34).** Available if wanted; neither is wired up.
4. **Button (35).** Enabled as `C_BTN`, but GPIO35 has no internal pull-up.
   Confirm the board actually has an external one before trusting it.
5. **Upstream PR.** The change set is deliberately small and follows the
   existing per-board pattern, so it could plausibly be offered upstream —
   but do that only after it is verified on hardware.

---

## 11. Artefacts and paths

> **This folder is self-contained.** Everything needed to build, flash, or
> restore this board lives under `C:\Users\anon\anti-projects\MarauderNicePort`.
> The board dumps that were originally taken into `D:\Desktop\WirelessWizard\`
> were copied to `board-backup\` here and hash-verified. That WirelessWizard
> folder is safe to delete; it held only those dumps plus three publicly
> downloadable Wireless Wizard firmware images.

| What | Where |
|---|---|
| This fork | `C:\Users\anon\anti-projects\MarauderNicePort` |
| New board driver | `esp32_marauder\cst816d.h` |
| New TFT setup | `User_Setup_cyd_nicemcu.h` |
| Build script | `tools\build_nicemcu.ps1` |
| Build log | `build_nicemcu.log` |
| Stock 4 MB backup | `C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin` |
| Board identification evidence | `C:\Users\anon\anti-projects\MarauderNicePort\board-backup\` (partition table, app header, 1.25 MB app dump) |
| NiceMCU factory source | <https://github.com/NiceMCU-01/NiceMCU-32S-DEV_2.8IPS> |
| Marauder CI build matrix | `.github/workflows/build_parallel.yml` |

---

## 12. One-paragraph summary for a fresh agent

Mike wants ESP32 Marauder running on a NiceMCU-32S-DEV 2.8" IPS board (ESP32
classic, 4 MB, ST7789 240×320, CST816D I2C touch). A fork already exists at
`C:\Users\anon\anti-projects\MarauderNicePort` with a new `MARAUDER_CYD_NICEMCU`
target, a CST816D driver aliased onto Marauder's existing capacitive-touch path,
and an ST7789 TFT setup header. Build it with
`tools\build_nicemcu.ps1`, flash it with arduino-cli, and verify via the
115200 serial log line `[Touch] CST816D probe ... ok` plus a working display
and tap response. The stock firmware backup is at
`C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin` — do not delete
it. SD card support is the first missing feature, blocked on an unknown
chip-select pin.
