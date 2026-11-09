# STATUS — MarauderNicePort

| Field | Value |
|---|---|
| Project | ESP32 Marauder port to NiceMCU-32S-DEV 2.8" IPS |
| State | **WORKING on hardware** — display, touch, brightness all verified |
| Target board | NiceMCU-32S-DEV 2.8IPS (ESP32-D0WD-V3, MAC `70:4b:ca:30:19:e4`, 4 MB, ST7789 240×320, CST816D I2C touch) |
| Upstream | justcallmekoko/ESP32Marauder, master, v1.20.0 (MIT) |
| Public repo | https://github.com/Zelray/ESP32Marauder-NiceMCU |
| Published release | v1.20.0-nicemcu (merged 4 MB image attached) |
| New board target | `MARAUDER_CYD_NICEMCU` |
| Build command | `pwsh -NoProfile -File tools\build_nicemcu.ps1` |
| Build status | **SUCCESS** — 1,970,143 B app (93%), ~77 KB RAM |
| Toolchain | arduino-cli 1.5.1 · esp32 core 3.3.4 · NimBLE 2.3.8 · TFT_eSPI 2.5.34 |
| FQBN | `esp32:esp32:d32:PartitionScheme=no_ota` (+ `-Wl,-zmuldefs`) |
| Final image | `build_nicemcu\esp32_marauder.ino.merged.bin` (4 MB, SHA256 `35B603AC…E8A9`) |
| Verified on hardware | colours (inversion ON), capacitive touch, brightness menu, boot health |
| Known hardware limits | backlight max is the board's ceiling (active-low MOSFET); SD chip-select unknown |
| Disabled on purpose | on-board key GPIO35 (input-only, no pull → phantom presses) |
| Rollback image | `board-backup\nicemcu-stock-full-4mb.bin` (SHA256 `DBCC6CCD…E22981`) |
| Detail | `HANDOFF.md` |
