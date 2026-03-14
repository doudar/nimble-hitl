#include <Arduino.h>

#include "app/command_protocol.h"
#include "app/device_state.h"
#include "app/nimble_engine.h"
#include "app/telemetry_reporter.h"

namespace {
static constexpr uint8_t kLedPin = 2;

DeviceState deviceState;
CommandProtocol protocol;
NimbleEngine engine(deviceState, protocol);
TelemetryReporter telemetry(deviceState, protocol, engine);
String serialBuffer;
bool awaitingSerialHandshake = true;
unsigned long lastReadyBeaconMs = 0;
unsigned long lastLedToggleMs = 0;
bool ledState = false;

void publishFrame(const String& frame) {
  Serial.print(frame);
  engine.publishToBle(frame);
}

void publishStartupEvent() {
  JsonDocument payload;
  payload["deviceId"] = deviceState.deviceId;
  payload["resetReason"] = deviceState.resetReason;
  payload["architecture"] = deviceState.architecture;
  Serial.print(protocol.encodeEvent(deviceState.deviceId, "boot", payload));
}

void publishReadyBeacon() {
  Serial.print(protocol.encodeLog(deviceState.deviceId, "ready-for-connection"));
}

void processFrame(const String& rawFrame) {
  ParsedCommand command;
  String error;
  if (!protocol.decode(rawFrame, command, error)) {
    Serial.print(protocol.encodeLog(deviceState.deviceId, "decode-error: " + error));
    return;
  }

  if (deviceState.controlTransport != "serial") {
    Serial.print(protocol.encodeLog(deviceState.deviceId,
                                    "serial-control-disabled-while-ble-active"));
    return;
  }

  awaitingSerialHandshake = false;
  engine.handleCommand(command);
}
}  // namespace

void setup() {
  Serial.begin(921600);
  delay(250);
  pinMode(kLedPin, OUTPUT);
  digitalWrite(kLedPin, LOW);
  deviceState.refreshTelemetry();
  engine.begin(publishFrame);
  telemetry.begin(publishFrame);
  publishStartupEvent();
}

void loop() {
  const auto now = millis();

  // Blink the onboard LED every second as a heartbeat.
  if (now - lastLedToggleMs >= 500) {
    ledState = !ledState;
    digitalWrite(kLedPin, ledState ? HIGH : LOW);
    lastLedToggleMs = now;
  }

  if (awaitingSerialHandshake) {
    if (now - lastReadyBeaconMs >= 2000) {
      publishReadyBeacon();
      lastReadyBeaconMs = now;
    }
  }

  while (Serial.available() > 0) {
    const char incoming = static_cast<char>(Serial.read());
    if (incoming == '\r') {
      continue;
    }

    if (incoming == '\n') {
      if (!serialBuffer.isEmpty()) {
        processFrame(serialBuffer);
        serialBuffer = "";
      }
      continue;
    }

    serialBuffer += incoming;
    if (serialBuffer.length() > 4096) {
      const String overflowFrame =
          protocol.encodeLog(deviceState.deviceId,
                             "serial-buffer-overflow-dropped-frame");
      Serial.print(overflowFrame);
      engine.publishToBle(overflowFrame);
      serialBuffer = "";
    }
  }

  engine.loop();
  delay(1);
}
