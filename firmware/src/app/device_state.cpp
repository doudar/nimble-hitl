#include "device_state.h"

namespace {
String resetReasonToString(const esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON:
      return "power_on";
    case ESP_RST_EXT:
      return "external";
    case ESP_RST_SW:
      return "software";
    case ESP_RST_PANIC:
      return "panic";
    case ESP_RST_INT_WDT:
      return "interrupt_watchdog";
    case ESP_RST_TASK_WDT:
      return "task_watchdog";
    case ESP_RST_WDT:
      return "watchdog";
    case ESP_RST_DEEPSLEEP:
      return "deep_sleep";
    case ESP_RST_BROWNOUT:
      return "brownout";
    case ESP_RST_SDIO:
      return "sdio";
    default:
      return "unknown";
  }
}
}  // namespace

DeviceState::DeviceState()
    : deviceId(String(static_cast<uint32_t>(ESP.getEfuseMac()), HEX)),
      deviceName("nimble-hitl"),
      activeRole("idle"),
      controlTransport("serial"),
      architecture(
#if defined(TARGET_ESP32_S3)
          "ESP32-S3"
#elif defined(TARGET_ESP32_C3)
          "ESP32-C3"
#else
          "ESP32"
#endif
      ),
      mtu(23),
      freeHeap(0),
      minimumFreeHeap(0),
      resetReason(resetReasonToString(esp_reset_reason())) {}

void DeviceState::refreshTelemetry() {
  freeHeap = esp_get_free_heap_size();
  minimumFreeHeap = esp_get_minimum_free_heap_size();
}

void DeviceState::setRole(const String& nextRole) { activeRole = nextRole; }

void DeviceState::setTransport(const String& nextTransport) {
  controlTransport = nextTransport;
}

void DeviceState::setLastError(const String& error) { lastError = error; }

void DeviceState::clearLastError() { lastError = ""; }

void DeviceState::setDeviceName(const String& nextName) { deviceName = nextName; }

void DeviceState::fillTelemetryPayload(JsonObject payload) const {
  payload["deviceId"] = deviceId;
  payload["deviceName"] = deviceName;
  payload["activeRole"] = activeRole;
  payload["transport"] = controlTransport;
  payload["mtu"] = mtu;
  payload["freeHeap"] = freeHeap;
  payload["minimumFreeHeap"] = minimumFreeHeap;
  payload["architecture"] = architecture;
  payload["updatedAt"] = millis();
  payload["lastError"] = lastError;
}

void DeviceState::fillDiagnosticsPayload(JsonObject payload) const {
  payload["deviceId"] = deviceId;
  payload["resetReason"] = resetReason;
  payload["architecture"] = architecture;
  payload["freeHeap"] = freeHeap;
  payload["minimumFreeHeap"] = minimumFreeHeap;
  payload["lastError"] = lastError;
}

