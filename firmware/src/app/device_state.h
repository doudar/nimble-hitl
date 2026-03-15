#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

#include <esp_heap_caps.h>
#include <esp_system.h>

class DeviceState {
 public:
  DeviceState();

  void refreshTelemetry();
  void setRole(const String& nextRole);
  void setTransport(const String& nextTransport);
  void setLastError(const String& error);
  void clearLastError();
  void setDeviceName(const String& nextName);

  void fillTelemetryPayload(JsonObject payload) const;
  void fillDiagnosticsPayload(JsonObject payload) const;

  String deviceId;
  String deviceName;
  String activeRole;
  String controlTransport;
  String architecture;
  uint16_t mtu;
  uint32_t freeHeap;
  uint32_t minimumFreeHeap;
  String lastError;
  String resetReason;
};

