#pragma once

#include <Arduino.h>

#include "command_protocol.h"
#include "device_state.h"
#include "nimble_engine.h"

class TelemetryReporter {
 public:
  TelemetryReporter(DeviceState& state, CommandProtocol& protocol,
                    NimbleEngine& engine);
  ~TelemetryReporter();

  void begin(FramePublisher publisher, uint32_t intervalMs = 2000);
  void stop();

 private:
  static void taskMain(void* context);
  void run();

  DeviceState& state_;
  CommandProtocol& protocol_;
  NimbleEngine& engine_;
  FramePublisher publisher_;
  TaskHandle_t taskHandle_ = nullptr;
  uint32_t intervalMs_ = 2000;
  bool running_ = false;
};

