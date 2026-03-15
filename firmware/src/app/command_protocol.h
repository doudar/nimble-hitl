#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

#include <functional>

#include "device_state.h"

using FramePublisher = std::function<void(const String&)>;

struct ParsedCommand {
  String id;
  String kind;
  String type;
  String target;
  JsonDocument payload;
};

class CommandProtocol {
 public:
  bool decode(const String& rawFrame, ParsedCommand& command, String& error) const;

  String encodeResponse(const String& requestId, const String& target,
                        const String& type, bool ok, const String& message,
                        const JsonDocument& payload) const;
  String encodeTelemetry(const String& target, const DeviceState& state) const;
  String encodeEvent(const String& target, const String& type,
                     const JsonDocument& payload) const;
  String encodeLog(const String& target, const String& message) const;

  private:
  String encodeFrame(const String& id, const String& kind, const String& type,
                     const String& target, const JsonDocument& payload) const;
};

