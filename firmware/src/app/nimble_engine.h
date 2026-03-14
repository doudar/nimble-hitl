#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>

#include "command_protocol.h"
#include "device_state.h"

class NimbleEngine;

class ControlCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit ControlCharacteristicCallbacks(NimbleEngine* engine);

 protected:
  void onWrite(NimBLECharacteristic* characteristic) override;

 private:
  NimbleEngine* engine_;
};

class DataCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit DataCharacteristicCallbacks(NimbleEngine* engine);

 protected:
  void onWrite(NimBLECharacteristic* characteristic) override;

 private:
  NimbleEngine* engine_;
};

class NimbleEngine {
 public:
  NimbleEngine(DeviceState& state, CommandProtocol& protocol);

  void begin(FramePublisher publisher);
  bool handleCommand(const ParsedCommand& command);
  bool handleRawBleFrame(const String& rawFrame);
  void publishToBle(const String& frame);
  void publishEvent(const String& type, const JsonDocument& payload);
  void loop();

  private:
  void publishResponse(const ParsedCommand& command, bool ok,
                       const String& message,
                       const JsonDocument& payload);
  void publishError(const ParsedCommand& command, const String& message);

  void ensureServer();
  void ensureClient();
  void ensureControlService();
  void resetRoles();
  void resetServerObjects();
  void setupAdvertising(const ParsedCommand& command);
  bool runStressPass(const ParsedCommand& command);

  DeviceState& state_;
  CommandProtocol& protocol_;
  FramePublisher publisher_;

  NimBLEServer* server_ = nullptr;
  NimBLEService* service_ = nullptr;
  NimBLECharacteristic* dataCharacteristic_ = nullptr;
  NimBLEDescriptor* descriptor_ = nullptr;
  NimBLEAdvertising* advertising_ = nullptr;
  NimBLEClient* client_ = nullptr;
  NimBLERemoteCharacteristic* remoteCharacteristic_ = nullptr;
  NimBLEService* controlService_ = nullptr;
  NimBLECharacteristic* controlRxCharacteristic_ = nullptr;
  NimBLECharacteristic* controlTxCharacteristic_ = nullptr;
  ControlCharacteristicCallbacks controlCallbacks_;
  DataCharacteristicCallbacks dataCallbacks_;
  String characteristicValue_;
};

