# build_nicemcu.ps1 — build ESP32 Marauder for the NiceMCU-32S-DEV 2.8" IPS board.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Marauder's firmware is an Arduino sketch (esp32_marauder/esp32_marauder.ino),
# not a PlatformIO project. Upstream builds it in CI with arduino-cli plus a
# specific pile of libraries (see .github/workflows/build_parallel.yml). This
# script reproduces that CI build locally for one new target:
#
#     MARAUDER_CYD_NICEMCU  — NiceMCU-32S-DEV 2.8" IPS
#                             ESP32-D0WD-V3, 4 MB flash, ST7789 240x320,
#                             CST816D capacitive touch on I2C.
#
# It is deliberately NOT a PlatformIO env: upstream pins library versions and
# core versions that PlatformIO would silently resolve differently, and the
# first failure mode you want is "wrong library version", not "weird linker
# error three minutes in".
#
# WHAT IT DOES (in order)
#   1. Installs arduino-cli if it is not already on PATH (into %USERPROFILE%\bin).
#   2. Installs the esp32 core at 3.3.4 — the version upstream CI pairs with
#      the NimBLE-2 / HAS_IDF_3 board profiles. Core 2.0.11 is only used for the
#      older NimBLE-1 boards (CYD_MICRO, GUITION, 3.5"), and fails here on
#      WIFI_AUTH_WPA3_ENTERPRISE and duplicate definitions.
#   3. Populates a local library tree (.build-libs) with the exact versions
#      upstream CI installs, and with our TFT_eSPI User_Setup.h written in.
#   4. Compiles the sketch with -DMARAUDER_CYD_NICEMCU.
#
# Anything already present is left alone, so re-running only does the missing
# work. Pass -Clean to wipe the library tree and the build output first.

[CmdletBinding()]
param(
    [switch]$Clean,
    [string]$Port          # optional: COM port to upload to after a successful build
)

$ErrorActionPreference = "Stop"

# Repo root = parent of the folder this script lives in (tools/).
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$LibsDir   = Join-Path $RepoRoot ".build-libs"
$BuildDir  = Join-Path $RepoRoot "build_nicemcu"
$CliDir    = Join-Path $env:USERPROFILE "bin"
$CliExe    = Join-Path $CliDir "arduino-cli.exe"

# Everything upstream CI installs for ESP32 (Xtensa) targets. The refs matter:
# NimBLE 1.3.8 in particular has a different API from the 2.x line.
$Libraries = @(
    @{ repo = "marian-craciunescu/ESP32Ping";     ref = "1.6"     },
    @{ repo = "ESP32Async/AsyncTCP";              ref = "v3.4.8"  },
    @{ repo = "ESP32Async/ESPAsyncWebServer";     ref = "v3.8.1"  },
    @{ repo = "stevemarple/MicroNMEA";            ref = "v2.0.6"  },
    @{ repo = "PaulStoffregen/XPT2046_Touchscreen"; ref = "v1.4"  },
    @{ repo = "lvgl/lv_arduino";                  ref = "3.0.0"   },
    @{ repo = "Bodmer/JPEGDecoder";               ref = "1.8.0"   },
    # NOTE: upstream's CI matrix lists 1.3.8 for the older CYD targets, but
    # master (v1.20.0) is written against the NimBLE **2.x** API — const
    # NimBLEAdvertisedDevice callbacks, setScanCallbacks(), getManufacturerData()
    # returning std::vector, isLegacyAdvertisement(). Building with 1.3.8 fails
    # with ~40 type errors. 2.3.8 is the version that matches the source.
    @{ repo = "h2zero/NimBLE-Arduino";            ref = "2.3.8"   },
    @{ repo = "adafruit/Adafruit_NeoPixel";       ref = "1.12.0"  },
    @{ repo = "bblanchon/ArduinoJson";            ref = "v6.18.2" },
    @{ repo = "ivanseidel/LinkedList";            ref = "v1.3.3"  },
    @{ repo = "plerup/espsoftwareserial";         ref = "8.1.0"   },
    @{ repo = "adafruit/Adafruit_BusIO";          ref = "1.15.0"  },
    @{ repo = "adafruit/Adafruit_MAX1704X";       ref = "1.0.2"   }
)

# TFT_eSPI is handled separately: upstream uses the Bodmer fork at V2.5.34, and
# our board needs a specific User_Setup.h dropped into the library root.
$TftRepo = "Bodmer/TFT_eSPI"
$TftRef  = "V2.5.34"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. arduino-cli
# ---------------------------------------------------------------------------
if (-not (Get-Command arduino-cli -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $CliExe)) {
        Write-Step "Installing arduino-cli into $CliDir"
        New-Item -ItemType Directory -Force -Path $CliDir | Out-Null
        $ver = (Invoke-RestMethod "https://api.github.com/repos/arduino/arduino-cli/releases/latest").tag_name.TrimStart("v")
        $zip = Join-Path $env:TEMP "arduino-cli_$ver.zip"
        Invoke-WebRequest "https://github.com/arduino/arduino-cli/releases/download/v$ver/arduino-cli_${ver}_Windows_64bit.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $CliDir -Force
    }
    $env:PATH = "$CliDir;$env:PATH"
}
Write-Step ("arduino-cli: " + (& arduino-cli version))

# ---------------------------------------------------------------------------
# 2. ESP32 core 2.0.11
# ---------------------------------------------------------------------------
Write-Step "Ensuring esp32:esp32 core 3.3.4"
& arduino-cli core update-index | Out-Null
$cores = & arduino-cli core list
if (-not ($cores -match "esp32:esp32\s+3\.3\.4")) {
    & arduino-cli core install esp32:esp32@3.3.4
}
if ($LASTEXITCODE -ne 0) { throw "esp32 core install failed" }

# ---------------------------------------------------------------------------
# 3. Libraries
# ---------------------------------------------------------------------------
if ($Clean -and (Test-Path $LibsDir)) {
    Write-Step "Clean: removing $LibsDir and $BuildDir"
    Remove-Item -Recurse -Force $LibsDir, $BuildDir
}
New-Item -ItemType Directory -Force -Path $LibsDir | Out-Null

function Get-Library([string]$Repo, [string]$Ref) {
    $name = Split-Path -Leaf $Repo
    $dest = Join-Path $LibsDir $name
    if (Test-Path $dest) { return }
    Write-Step "Fetching $Repo @ $Ref"
    # Shallow clone of the tag/branch, then drop .git so arduino-cli treats it
    # as a plain library folder.
    & git clone --quiet --depth 1 --branch $Ref "https://github.com/$Repo.git" $dest
    if ($LASTEXITCODE -ne 0) { throw "clone failed: $Repo @ $Ref" }
    Remove-Item -Recurse -Force (Join-Path $dest ".git") -ErrorAction SilentlyContinue
}

foreach ($lib in $Libraries) { Get-Library $lib.repo $lib.ref }

# TFT_eSPI + our board setup.
Get-Library $TftRepo $TftRef
$tftDir = Join-Path $LibsDir "TFT_eSPI"
$setupSrc = Join-Path $RepoRoot "User_Setup_cyd_nicemcu.h"
$setupDst = Join-Path $tftDir "User_Setup.h"
Write-Step "Installing NiceMCU TFT_eSPI setup"
Copy-Item $setupSrc $setupDst -Force
# TFT_eSPI picks User_Setup.h automatically because User_Setup_Select.h includes
# it by default. USER_SETUP_LOADED is only needed when you include a setup file
# directly; we must NOT define it, or the library refuses to load ours.

# ---------------------------------------------------------------------------
# 4. Compile
# ---------------------------------------------------------------------------
Write-Step "Compiling esp32_marauder for MARAUDER_CYD_NICEMCU"
# no_ota: 2,097,152-byte app partition, 1.875 MB SPIFFS. The CYD profiles use
# min_spiffs (1,966,080 bytes) and this build lands at 1,970,727 — ~4.6 KB over.
# The d32 board only offers default/minimal/no_ota/min_spiffs (no huge_app), so
# no_ota is the only scheme with room. Cost: no OTA slot (no app1), so firmware
# updates are USB- or SD-based.
$fqbn = "esp32:esp32:d32:PartitionScheme=no_ota"

# -Wl,-zmuldefs is REQUIRED, not a convenience.
#
# Upstream's CI literally edits platform.txt:
#     sed -i 's/compiler.c.elf.extra_flags=/compiler.c.elf.extra_flags=-Wl,-zmuldefs /'
# because Marauder's source relies on duplicate symbols being tolerated:
#   * WiFiScan.h defines `bool connectionPending` / `operationInProgress` at
#     namespace scope inside a header (one per translation unit), and
#   * WiFiScan.cpp defines ieee80211_raw_frame_sanity_check(), which collides
#     with the copy inside the precompiled IDF WiFi library on core 3.x.
# Without this flag the link dies with "multiple definition of ...".
& arduino-cli compile `
    --fqbn $fqbn `
    --libraries $LibsDir `
    --build-property "compiler.cpp.extra_flags=-DMARAUDER_CYD_NICEMCU" `
    --build-property "compiler.c.extra_flags=-DMARAUDER_CYD_NICEMCU" `
    --build-property "compiler.c.elf.extra_flags=-Wl,-zmuldefs" `
    --output-dir $BuildDir `
    (Join-Path $RepoRoot "esp32_marauder")

if ($LASTEXITCODE -ne 0) {
    throw "compile failed - see the output above"
}

Write-Step "Build artifacts"
Get-ChildItem $BuildDir -Filter *.bin | Select-Object Name, Length | Format-Table -AutoSize

# ESP32 classic bootloader lives at 0x1000, so the .ino.bin is flashed at
# 0x10000 only after bootloader + partition table. Use the merged image if the
# toolchain produced one; otherwise flash the three parts (see HANDOFF.md).

if ($Port) {
    Write-Step "Uploading to $Port"
    & arduino-cli upload -p $Port --fqbn $fqbn --input-dir $BuildDir (Join-Path $RepoRoot "esp32_marauder")
}
