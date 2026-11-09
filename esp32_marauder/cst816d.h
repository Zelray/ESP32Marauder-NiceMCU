#pragma once

#ifndef cst816d_h
#define cst816d_h

// CST816D capacitive touch controller — NiceMCU-32S-DEV 2.8" IPS.
//
// This exists next to ft6336.h because Marauder's capacitive-touch path was
// written for the FT6336. The two parts speak different I2C dialects:
//
//   FT6336  : address 0x38, status in register 0x02, 7-byte packet
//   CST816D : address 0x15, finger count in register 0x02, 5-byte packet
//
// Everything else in Marauder (rotation math, edge rejection, the "return 1
// pressed / 0 released / -1 transport error" contract) is shared, so this file
// only has to satisfy that same contract.
//
// Protocol confirmed against NiceMCU's factory firmware source:
//   https://github.com/NiceMCU-01/NiceMCU-32S-DEV_2.8IPS
//   src/nicemcu_display.cpp — read_touch() / the kTouchDataRegister = 0x02 read.

#ifdef HAS_CAP_TOUCH

#include <Arduino.h>
#include <Wire.h>
#include "configs.h"

// Board-level constants. CTP_SDA / CTP_SCL / CTP_INT are set per board in
// configs.h, exactly like the FT6336 path expects.
#ifndef CST816D_ADDR
  #define CST816D_ADDR 0x15
#endif

#define CST816D_DATA_REG   0x02
#define CST816D_PACKET_LEN 5

// Diagnostic: log raw touch samples to the serial port (max ~5 per second).
// Touch is confirmed working on the NiceMCU board, so this is off. Set to 1
// if touch ever regresses and you want to see the controller's raw output.
#define CST816D_DEBUG 0

// One transactional read of the touch packet.
// Returns true only when the controller ACKed and delivered every byte.
static bool cst816d_read_packet(uint8_t *buf, uint8_t len) {
  Wire.beginTransmission(CST816D_ADDR);
  Wire.write((uint8_t)CST816D_DATA_REG);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  const uint8_t received = Wire.requestFrom((int)CST816D_ADDR, (int)len);
  if (received != len) {
    // Drain anything the slave did send so the next read starts clean.
    while (Wire.available() > 0) {
      Wire.read();
    }
    return false;
  }

  for (uint8_t i = 0; i < len; i++) {
    buf[i] = (uint8_t)Wire.read();
  }
  return true;
}

static void cst816d_init() {
  // A separate touch reset only exists on some boards. NiceMCU ties the panel
  // and touch reset together on GPIO2, which TFT_eSPI already toggles during
  // display init, so CTP_RST is -1 here and this block is skipped.
  #if defined(CTP_RST) && (CTP_RST >= 0)
    pinMode(CTP_RST, OUTPUT);
    digitalWrite(CTP_RST, LOW);
    delay(10);
    digitalWrite(CTP_RST, HIGH);
    delay(50);
  #endif

  Wire.begin(CTP_SDA, CTP_SCL, 400000U);

  #if defined(CTP_INT) && (CTP_INT >= 0)
    pinMode(CTP_INT, INPUT);
  #endif

  // A single probe read tells us at boot whether the controller is alive.
  // It is harmless on success and extremely useful in the serial log when it
  // is not — a dead touch controller is otherwise indistinguishable from a
  // firmware that simply ignores taps.
  uint8_t probe[CST816D_PACKET_LEN] = {0};
  Serial.printf("[Touch] CST816D probe on SDA %d / SCL %d: %s\n",
                (int)CTP_SDA, (int)CTP_SCL,
                cst816d_read_packet(probe, CST816D_PACKET_LEN) ? "ok" : "NO ACK");
}

// Same contract as ft6336_read_raw():
//    1 = a finger is down (raw_x/raw_y filled)
//    0 = no touch
//   -1 = I2C transport failure
static int8_t cst816d_read_raw(uint16_t *raw_x, uint16_t *raw_y) {
  uint8_t p[CST816D_PACKET_LEN] = {0};
  if (!cst816d_read_packet(p, CST816D_PACKET_LEN)) {
    return -1;
  }

  // packet[0] is the finger count; zero means "released".
  if (p[0] == 0) {
    return 0;
  }

  // 12-bit coordinates: high nibble in [1]/[3], low byte in [2]/[4].
  *raw_x = (uint16_t)(((p[1] & 0x0F) << 8) | p[2]);
  *raw_y = (uint16_t)(((p[3] & 0x0F) << 8) | p[4]);

  #if CST816D_DEBUG
    // Throttled so a held finger does not flood the console, but the first
    // sample of every press still prints immediately.
    static unsigned long last_debug_ms = 0;
    if (millis() - last_debug_ms > 200) {
      last_debug_ms = millis();
      Serial.printf("[Touch] fingers=%u raw=(%u,%u)\n", p[0], *raw_x, *raw_y);
    }
  #endif

  return 1;
}

// Kept for parity with ft6336_update(); nothing in Marauder calls it yet.
static uint8_t cst816d_update(uint16_t *x, uint16_t *y) {
  uint16_t raw_x, raw_y;
  if (cst816d_read_raw(&raw_x, &raw_y) != 1) {
    return 0;
  }
  *x = raw_x;
  *y = raw_y;
  return 1;
}

#endif  // HAS_CAP_TOUCH
#endif  // cst816d_h
