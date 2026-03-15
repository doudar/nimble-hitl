#include "telemetry_reporter.h"

TelemetryReporter::TelemetryReporter(DeviceState& state, CommandProtocol& protocol,
                                     NimbleEngine& engine)
    : state_(state), protocol_(protocol), engine_(engine) {}

TelemetryReporter::~TelemetryReporter() { stop(); }

void TelemetryReporter::begin(FramePublisher publisher, uint32_t intervalMs) {
  publisher_ = std::move(publisher);
  intervalMs_ = intervalMs;
  running_ = true;
  xTaskCreatePinnedToCore(taskMain, "telemetry_reporter", 4096, this, 1,
                          &taskHandle_, 1);
}

void TelemetryReporter::stop() {
  running_ = false;
  if (taskHandle_ != nullptr) {
    vTaskDelay(pdMS_TO_TICKS(intervalMs_ + 50));
    if (taskHandle_ != nullptr) {
      vTaskDelete(taskHandle_);
      taskHandle_ = nullptr;
    }
  }
}

void TelemetryReporter::taskMain(void* context) {
  static_cast<TelemetryReporter*>(context)->run();
}

void TelemetryReporter::run() {
  while (running_) {
    state_.refreshTelemetry();
    const String frame = protocol_.encodeTelemetry(state_.deviceId, state_);
    publisher_(frame);
    engine_.publishToBle(frame);
    vTaskDelay(pdMS_TO_TICKS(intervalMs_));
  }
  taskHandle_ = nullptr;
  vTaskDelete(nullptr);
}

