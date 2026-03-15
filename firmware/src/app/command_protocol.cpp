#include "command_protocol.h"

bool CommandProtocol::decode(const String& rawFrame, ParsedCommand& command,
                             String& error) const {
  JsonDocument envelope;
  const auto parseError = deserializeJson(envelope, rawFrame);
  if (parseError) {
    error = parseError.c_str();
    return false;
  }

  command.id = envelope["id"] | "";
  command.kind = envelope["kind"] | "command";
  command.type = envelope["type"] | "";
  command.target = envelope["target"] | "";
  command.payload.clear();
  command.payload.set(envelope["payload"] | JsonObjectConst());
  return true;
}

String CommandProtocol::encodeResponse(const String& requestId,
                                       const String& target,
                                       const String& type, bool ok,
                                       const String& message,
                                       const JsonDocument& payload) const {
  JsonDocument response;
  response["ok"] = ok;
  response["message"] = message;
  response["data"].set(payload.as<JsonVariantConst>());
  return encodeFrame(requestId, "response", type, target, response);
}

String CommandProtocol::encodeTelemetry(const String& target,
                                        const DeviceState& state) const {
  JsonDocument payload;
  state.fillTelemetryPayload(payload.to<JsonObject>());
  return encodeFrame(String(millis()), "telemetry", "telemetry", target, payload);
}

String CommandProtocol::encodeEvent(const String& target, const String& type,
                                    const JsonDocument& payload) const {
  return encodeFrame(String(millis()), "event", type, target, payload);
}

String CommandProtocol::encodeLog(const String& target,
                                  const String& message) const {
  JsonDocument payload;
  payload["message"] = message;
  return encodeFrame(String(millis()), "log", "log", target, payload);
}

String CommandProtocol::encodeFrame(const String& id, const String& kind,
                                    const String& type, const String& target,
                                    const JsonDocument& payload) const {
  JsonDocument frame;
  frame["id"] = id;
  frame["kind"] = kind;
  frame["type"] = type;
  frame["target"] = target;
  frame["timestamp"] = static_cast<uint32_t>(millis());
  frame["payload"].set(payload.as<JsonVariantConst>());

  String encoded;
  serializeJson(frame, encoded);
  encoded += '\n';
  return encoded;
}

