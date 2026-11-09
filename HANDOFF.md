# HANDOFF — ESP32 Marauder on the NiceMCU-32S-DEV 2.8" IPS

Last updated **2026-11-08**. This document is the single source of truth for the
port. Read it top to bottom before touching the board.

Everything here is either read off the hardware, taken from a primary source, or
explicitly marked as unverified.

---

## 1. Current state

| Item | State |
|---|---|
| Board target `MARAUDER_CYD_NICEMCU` | **Done, working** |
| Compiles cleanly | **YES** — 1,970,143 B app (93% of 2 MB) |
| Flashed to hardware | **YES** — merged image at `0x0`, hash verified |
| Display | **Verified** — colours correct, orientation correct |
| Capacitive touch | **Verified** — taps register and land correctly |
| Brightness control | **Verified** — menu now dims and brightens correctly |
| Boot health | **Clean** — no GPIO errors, no phantom headless mode |
| microSD | **Stubbed** — `SD_CS = -1`, mounting fails cleanly, features inert |
| RGB LED / speaker / VBAT | Not implemented |
| Public repo | <https://github.com/Zelray/ESP32Marauder-NiceMCU> |
| Public release | <https://github.com/Zelray/ESP32Marauder-NiceMCU/releases/tag/v1.20.0-nicemcu> |
| Stock firmware backup | `board-backup\nicemcu-stock-full-4mb.bin` — **do not delete** |

**Read §8 (rollback) before flashing anything.**

---

## 2. What this is

Mike wanted ESP32 Marauder on the **NiceMCU-32S-DEV 2.8" IPS**, a classic-ESP32
"CYD-class" board that Marauder has no target for. The board was chosen for its
pigtail antenna connector.

The port adds one board target. Upstream is
`justcallmekoko/ESP32Marauder` master at **v1.20.0**, MIT licensed
(© 2020 Just Call Me Koko — keep the `LICENSE` file with any redistribution).

### Dead ends already explored — do not repeat

- **Wireless Wizard does not support this board.** Its CYD targets (`cyd28`,
  `cyd28_hat`, `cyd24`, `cyd24_awok`, `cyd35`) are all classic ESP32 with
  ILI9341/ST7796 panels and **resistive XPT2046** touch. Its only ESP32-C5
  builds are the LilyGo T-Dongle C5 and Seeed XIAO C5 — screenless nodes.
- **HaleHound** ships only `esp32-cyd` and `esp32-cyd-hat`; also classic ESP32.
- **Bruce** runs on a *different* board (NM-CYD-C5, MAC `38:44:BE:24:8B:E0`).
  Unrelated. Leave it alone.

---

## 3. Board identification (verified)

| Property | Value | How |
|---|---|---|
| USB bridge | CH340 on **COM20**, `VID_1A86 / PID_7523` | Windows PnP |
| Chip | **ESP32-D0WD-V3 rev v3.1**, 40 MHz | `esptool flash-id` |
| MAC | `70:4b:ca:30:19:e4` | `esptool read-mac` |
| Flash | **4 MB** (Boya `68/4016`) | `esptool flash-id` |
| Board name | **NiceMCU-32S-DEV_2.8IPS** ("NiceMCU-01") | string literal in factory app |
| Display | **ST7789 240×320**, SPI | string literals + LVGL panel init |
| Touch | **CST816D**, I2C | string literal + I2C touch path |
| Factory firmware | "Factory UI", built 2024-03-05, IDF v4.4.7 | app descriptor |
| Vendor source | <https://github.com/NiceMCU-01/NiceMCU-32S-DEV_2.8IPS> | found by search |

An ESP32 classic has no native USB, so it enumerates as a **CH340**. That is the
fastest way to tell it apart from Mike's two ESP32-**C5** boards, which show up
as Espressif native USB (`VID 303A`, `PID 1001`).

---

## 4. Pin map (authoritative)

From NiceMCU `include/nicemcu/board_config.h` and their factory UI board map.

### Display — ST7789, SPI

| Signal | GPIO |
|---|---|
| MOSI | 13 |
| SCLK | 14 |
| CS | 15 |
| DC | 12 |
| RST | **2** — shared with touch |
| Backlight | 25 |
| MISO | not routed (write-only panel) |

### Touch — CST816D, I2C

| Signal | GPIO |
|---|---|
| SDA | 33 |
| SCL | 32 |
| INT | 36 |
| Address | `0x15` |
| Clock | 400 kHz |

### Other hardware (present, not implemented)

| Thing | GPIO |
|---|---|
| RGB LED | 4 / 16 / 17 — three discrete pins, **not** a WS2812 |
| Key/button | 35 — input-only, **no internal pull** |
| VBAT sense | 34 |
| Speaker | 26 |
| microSD | HSPI, card-detect 5, **chip-select unknown** |

---

## 5. The five hardware behaviours that matter

These each cost flash cycles to find. **Do not regress them.**

1. **Panel inversion is ON.** `TFT_INVERSION_ON` in `User_Setup_cyd_nicemcu.h`.
   With `OFF` the entire UI renders photo-negative.
2. **Touch must init AFTER `tft.init()`.** Panel and touch share reset on
   GPIO2. Marauder's original order (touch first) let `tft.init()` reset the
   controller straight afterwards — the probe printed `ok`, then no tap ever
   registered. Fixed in `Display.cpp`.
3. **Backlight is ACTIVE-LOW.** GPIO25 drives a P-channel MOSFET (AO3401)
   high-side switch. Measured: pin LOW = full, pin HIGH = dim, PWM 128 = half.
   `BL_SET` and `BL_PREVIEW` write `255 - duty` for this board, and
   `TFT_BACKLIGHT_ON LOW` stops TFT_eSPI's init leaving the panel dim.
   If undone: menu reads 100% while the panel sits at its dimmest.
4. **Key on GPIO35 stays disabled.** Input-only pad, no internal pull.
   `Switches(C_BTN, 1000, false)` requested a pull-down the pad cannot provide
   → `gpio_pulldown_en` errors, floating pin, phantom `justPressed()`, which
   sets `headless_mode = true` and calls `backlightOff()` — the screen
   "settling darker" seconds after boot. `HAS_BUTTONS` is off.
5. **Brightness ceiling is hardware.** Driving GPIO25 LOW is the maximum this
   circuit allows. "Not as bright as expected" is the panel/LED string, not a
   firmware setting.

---

## 6. What changed, file by file

### New: `esp32_marauder/cst816d.h`

CST816D driver exposing the **same contract** as Marauder's FT6336 driver:

- `1` = finger down (`raw_x` / `raw_y` filled)
- `0` = released
- `-1` = I2C transport error

Protocol (from NiceMCU `src/nicemcu_display.cpp`):

```
write register 0x02, read 5 bytes:
  [0] finger count (0 == released)
  [1] X high nibble (& 0x0F)   [2] X low
  [3] Y high nibble (& 0x0F)   [4] Y low
x = ((p[1] & 0x0F) << 8) | p[2]
y = ((p[3] & 0x0F) << 8) | p[4]
```

There is a `CST816D_DEBUG` switch (currently `0`). Set to `1` to log raw
samples — the first thing to do if touch ever regresses.

### `esp32_marauder/Display.h`

- Compile-time guard: `MARAUDER_CYD_NICEMCU` requires `ST7789_DRIVER`.
- `HAS_CAP_TOUCH` includes `cst816d.h` when `HAS_CST816D_TOUCH` is set, else the
  original `ft6336.h`.

### `esp32_marauder/Display.cpp`

- Aliases the new driver onto the existing capacitive path, so rotation
  transforms and edge rejection are reused unchanged:
  ```c
  #ifdef HAS_CST816D_TOUCH
    #define ft6336_init     cst816d_init
    #define ft6336_read_raw cst816d_read_raw
  #endif
  ```
- **Moved** the `HAS_CAP_TOUCH` init to *after* `tft.init()` / `setRotation()`
  (hardware behaviour #2).

### `esp32_marauder/esp32_marauder.ino`

- `BL_SET` writes `255 - duty` when `MARAUDER_CYD_NICEMCU` (hardware
  behaviour #3).

### `esp32_marauder/MenuFunctions.cpp`

- `BL_PREVIEW` in `brightnessMode()` inverts duty the same way, so the live
  preview matches the panel.

### `esp32_marauder/configs.h`

Follows the existing per-board pattern:

1. Board target line in the list at the top.
2. `HARDWARE_NAME "NiceMCU-32S-DEV 2.8 IPS"`.
3. Entry in the `HAS_CSI_MOTION` list.
4. **Capability block**: `HAS_TOUCH`, `HAS_CAP_TOUCH`, `HAS_CST816D_TOUCH`,
   `HAS_BT`, `HAS_BT_REMOTE`, `HAS_SCREEN`, `HAS_FULL_SCREEN`,
   `HAS_TEMP_SENSOR`, `HAS_CYD_PORTRAIT`, `HAS_NIMBLE_2`, `HAS_IDF_3`,
   `HAS_DIRECT_UPLOAD`, `HAS_SD` + `USE_SD` (link requirement, see below),
   `CTP_SDA 33`, `CTP_SCL 32`, `CTP_INT 36`, `CTP_RST -1`,
   `CAP_TOUCH_PANEL_WIDTH 240`, `CAP_TOUCH_PANEL_HEIGHT 320`.
   **Deliberately omitted**: `HAS_BUTTONS` (behaviour #4), `HAS_FLIPPER_LED`,
   `HAS_GPS`.
5. Button block: all buttons `-1`, `HAS_C` commented out.
6. Screen geometry block cloned from the CYD **2USB** profile (the existing
   240×320 ST7789 CYD target). Defines both `HAS_ILI9341` and `HAS_ST7789`.
7. Keypad geometry block, `MARAUDER_TITLE_BYTES 13578`.
8. `SD_CS -1` in the SD_CS block.

> **`HAS_ILI9341` is a capability flag, not a driver.** Marauder uses it as the
> "has a screen with touch" gate across `Display.cpp`, `MenuFunctions.cpp` and
> `WiFiScan.cpp`. The real panel driver comes from
> `User_Setup_cyd_nicemcu.h` (`ST7789_DRIVER`). Do not "clean this up".

> **`HAS_SD` cannot be omitted.** `HAS_DIRECT_UPLOAD` code in `CommandLine.cpp`
> (~line 700) and `MenuFunctions.cpp` (~1899–1935, 4049+) dereferences
> `sd_obj` with only `HAS_DIRECT_UPLOAD` around it, never `HAS_SD`. Without it
> the definition in `esp32_marauder.ino` is compiled out and the link fails with
> `undefined reference to 'sd_obj'`. Upstream never hits this because every
> shipped board defines `HAS_SD`.

### New: `User_Setup_cyd_nicemcu.h`

Cloned from `User_Setup_cyd_2usb.h`, then:

- `ST7789_DRIVER`, `TFT_WIDTH 240`, `TFT_HEIGHT 320`
- `TFT_MOSI 13`, `TFT_SCLK 14`, `TFT_CS 15`, `TFT_DC 12`, `TFT_RST 2`
  (DC/RST are **swapped** vs the 2USB template), `TFT_MISO -1`, `TFT_BL 25`
- `TFT_BACKLIGHT_ON LOW` (hardware behaviour #3)
- `TFT_INVERSION_ON` (behaviour #1)
- `TFT_RGB_ORDER TFT_BGR` kept from the template
- `TOUCH_CS` intentionally absent (no XPT2046)

### `User_Setup_Select.h`

Commented `//#include <User_Setup_cyd_nicemcu.h>` line for parity. Not used by
the build (the script copies the file into TFT_eSPI).

### New: `tools/build_nicemcu.ps1`

Reproduces upstream's CI build locally. See §7.

---

## 7. How to build

```powershell
pwsh -NoProfile -File C:\Users\anon\anti-projects\MarauderNicePort\tools\build_nicemcu.ps1
```

What it does:

1. Installs `arduino-cli` into `%USERPROFILE%\bin` if missing.
2. Installs **esp32 core 3.3.4** — the version paired with NimBLE-2 /
   `HAS_IDF_3` profiles in upstream CI. Core 2.0.11 is only correct for the
   older NimBLE-1 targets and fails here on `WIFI_AUTH_WPA3_ENTERPRISE`.
3. Clones the exact library versions from `.github/workflows/build_parallel.yml`
   into `.build-libs\` and copies `User_Setup_cyd_nicemcu.h` over
   `TFT_eSPI\User_Setup.h`.
4. Compiles:
   ```
   FQBN:  esp32:esp32:d32:PartitionScheme=no_ota
   CPP:   -DMARAUDER_CYD_NICEMCU
   Link:  -Wl,-zmuldefs
   ```
5. Writes artefacts to `build_nicemcu\`.

Options: `-Clean` wipes `.build-libs` + build output; `-Port COM20` uploads
after a successful build.

> **`-Wl,-zmuldefs` is mandatory.** Upstream CI patches `platform.txt`:
> `sed -i 's/compiler.c.elf.extra_flags=/compiler.c.elf.extra_flags=-Wl,-zmuldefs /'`
> Without it the link dies on duplicate symbols — `connectionPending` /
> `operationInProgress` (defined in a header) and
> `ieee80211_raw_frame_sanity_check` (`WiFiScan.cpp:126`, colliding with the
> copy in the precompiled IDF WiFi library). This is by design upstream.

> **Partition scheme must be `no_ota`.** The build lands ~4.6 KB over the
> `min_spiffs` app slot (1,966,080 B). `d32` offers only
> `default` / `minimal` / `no_ota` / `min_spiffs` (no `huge_app`), so `no_ota`
> (2,097,152 B app, 1.875 MB SPIFFS) is the only one with room. Cost: no OTA
> partition — updates are USB- or SD-based. Compile and upload must use the
> same scheme.

### Current build output

| Item | Value |
|---|---|
| Sketch | **1,970,143 bytes (93%)** of 2,097,152 |
| Static RAM | ~77 KB (24%) |
| Toolchain | arduino-cli 1.5.1 · esp32 core 3.3.4 · NimBLE-Arduino 2.3.8 · TFT_eSPI 2.5.34 |

| File | Size | SHA256 |
|---|---|---|
| `esp32_marauder.ino.merged.bin` | 4,194,304 | `35B603AC49F77CECCEC534E754093A1FB22A407BC7CE5723F3BD136A8BB1E8A9` |
| `esp32_marauder.ino.bin` | 1,970,288 | `B998AA8412A1D810C0EBB7D40D4759C675957F8FF6CA8FC38698C0702BAAF2B7` |
| `esp32_marauder.ino.bootloader.bin` | 23,664 | `38977B0FEBFDB370DC12CD7E4B48AEC60480005F6FA9D29E84BADDDD72CD01D2` |
| `esp32_marauder.ino.partitions.bin` | 3,072 | `6A88D59601A83A16A19A08114B59D338324B8DEC267D8B43E5D61AD56EC92102` |

### If a build fails

1. **Library drift** — compare every `ref` in `build_nicemcu.ps1` against
   `.github/workflows/build_parallel.yml`.
2. **NimBLE/core mismatch** — `HAS_NIMBLE_2` needs NimBLE 2.x, `HAS_IDF_3`
   needs core 3.x. Mismatch gives ~40 type errors.
3. **"text section exceeds available space"** — you are on a smaller partition
   scheme. Use `no_ota`.

---

## 8. Rollback (do this first if anything goes wrong)

The board's stock firmware **exists nowhere online**. A full 4 MB read was taken
before any write:

```
C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin
4,194,304 bytes
SHA256 DBCC6CCDA97A4587DD01BA59E1906277CDE61EAF1E7E01D73B22150F79E22981
```

Verify, then restore:

```powershell
(Get-FileHash "C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin" -Algorithm SHA256).Hash

python -m esptool -p COM20 -b 460800 write-flash 0x0 `
  "C:\Users\anon\anti-projects\MarauderNicePort\board-backup\nicemcu-stock-full-4mb.bin"
```

---

## 9. Flash and verify

```powershell
$img = "C:\Users\anon\anti-projects\MarauderNicePort\build_nicemcu\esp32_marauder.ino.merged.bin"
python -m esptool -p COM20 -b 460800 --chip esp32 write-flash `
  --flash-mode keep --flash-freq keep --flash-size keep 0x0 $img
```

The merged image is the whole 4 MB flash and is written at `0x0`.

### Expected boot log (115200)

```
ets Jul 29 2019 12:21:46
rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)
...
ESP-IDF version is: v5.5.1-710-g8410210c9a
[Touch] CST816D probe on SDA 33 / SCL 32: ok
Settings ...
Failed to mount SD Card          <-- expected, SD_CS is -1
SD Card NOT Supported
Changing to main menu...
      ESP32 Marauder
           v1.20.0
>
```

No `gpio_pulldown_en` errors should appear any more (button disabled).

### Checklist

1. Serial shows `[Touch] CST816D probe ... ok`. `NO ACK` = I2C problem — recheck
   §4.
2. Menu renders with correct colours, right way up.
3. Taps register and land on the intended row.
4. Brightness menu visibly changes the panel, in the right direction.
5. Device info reports `NiceMCU-32S-DEV 2.8 IPS`.

### Tuning knobs (User_Setup unless noted)

| Symptom | Fix |
|---|---|
| Photo-negative | must be `TFT_INVERSION_ON` (verified) |
| Red/blue swapped | swap `TFT_RGB_ORDER TFT_BGR` ↔ `TFT_RGB` |
| Blank screen | check `ST7789_DRIVER`, 240×320, try `SPI_FREQUENCY 20000000` |
| Backlight dim / inverted menu | check `TFT_BACKLIGHT_ON LOW` and the `BL_SET` inversion |
| Taps offset/mirrored | rotation transform in `Display::updateTouch()`, not in `cst816d.h` |
| Taps ignored | `CST816D_DEBUG 1`, then check raw samples in serial |
| Touch works then dies after boot | touch init must be **after** `tft.init()` |

---

## 10. Remaining work

1. **microSD — the main unfinished feature.** Stubbed with `SD_CS = -1`.
   The chip-select is not in NiceMCU's public `board_config.h`; it is in
   `docs/NiceMCU-32S-2.8IPS_原理图V2.0.pdf` in their repo — open the PDF
   itself, because text extraction flattened the net names and lost the mapping.
   Factory UI says `{"Bus","HSPI"}`, suggesting the card shares the display SPI
   bus (MOSI 13 / CLK 14) with a separate CS. Once known: set `SD_CS`; if the
   card has its own pins, also `SD_MISO`/`SD_MOSI`/`SD_SCK` + `HAS_SEPARATE_SD`.
2. **RGB LED (4/16/17).** Three discrete pins, not a WS2812. Do not define
   `HAS_NEOPIXEL_LED`.
3. **Speaker (26) / VBAT (34).** Available, unwired.
4. **Key (35).** Currently disabled by design. Only re-enable with a confirmed
   external pull-up.
5. **Upstream PR.** The change follows their per-board pattern and is a credible
   contribution. Recommended: use the board for a couple of weeks first, then
   submit, so SD/etc. can be included if they surface.

---

## 11. Paths and repo

| What | Where |
|---|---|
| Working copy | `C:\Users\anon\anti-projects\MarauderNicePort` |
| Public repo | <https://github.com/Zelray/ESP32Marauder-NiceMCU> (branch `nicemcu-32s-dev`, default) |
| Release w/ binary | <https://github.com/Zelray/ESP32Marauder-NiceMCU/releases/tag/v1.20.0-nicemcu> |
| Remotes | `origin` = upstream; `zelray` = the public fork |
| Board driver | `esp32_marauder\cst816d.h` |
| TFT setup | `User_Setup_cyd_nicemcu.h` |
| Build script | `tools\build_nicemcu.ps1` |
| Stock backup | `board-backup\nicemcu-stock-full-4mb.bin` |
| Other dumps | `board-backup\` (partition table, app header, 1.25 MB app dump) |
| Vendor source | <https://github.com/NiceMCU-01/NiceMCU-32S-DEV_2.8IPS> |
| Upstream CI matrix | `.github/workflows/build_parallel.yml` |

`board-backup/`, `.build-libs/`, `build_nicemcu/` and logs are gitignored and
must never be published — the backup is vendor firmware, not ours to
redistribute.

---

## 12. Summary for a fresh agent

Marauder already runs on this board. The fork is at
`C:\Users\anon\anti-projects\MarauderNicePort`, built with
`tools\build_nicemcu.ps1` and published at
<https://github.com/Zelray/ESP32Marauder-NiceMCU>.

Do not re-derive the hardware: the panel needs `TFT_INVERSION_ON`, touch must
initialise after `tft.init()` (shared reset on GPIO2), the backlight is
active-low behind a P-channel MOSFET so duty is inverted, and the GPIO35 key
must stay disabled. All five are explained in §5.

The one substantial piece of unfinished work is **microSD**, blocked on an
unknown chip-select pin that has to be read from the vendor schematic PDF.
