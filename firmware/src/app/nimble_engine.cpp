#include "nimble_engine.h"

namespace {
constexpr const char* kDefaultServiceUuid = "12345678-1234-5678-1234-56789abcdef1";
constexpr const char* kDefaultCharacteristicUuid =
    "12345678-1234-5678-1234-56789abcdef2";
constexpr const char* kDefaultDescriptorUuid =
    "2901";
constexpr const char* kControlServiceUuid = "12345678-1234-5678-1234-56789abcdef0";
constexpr const char* kControlRxUuid = "12345678-1234-5678-1234-56789abcdef3";
constexpr const char* kControlTxUuid = "12345678-1234-5678-1234-56789abcdef4";
}  // namespace

ControlCharacteristicCallbacks::ControlCharacteristicCallbacks(NimbleEngine* engine)
    : engine_(engine) {}

void ControlCharacteristicCallbacks::onWrite(
    NimBLECharacteristic* characteristic) {
  const std::string value = characteristic->getValue();
  engine_->handleRawBleFrame(String(value.c_str()));
}

DataCharacteristicCallbacks::DataCharacteristicCallbacks(NimbleEngine* engine)
    : engine_(engine) {}

void DataCharacteristicCallbacks::onWrite(
    NimBLECharacteristic* characteristic) {
  const std::string value = characteristic->getValue();
  JsonDocument payload;
  payload["value"] = value.c_str();
  payload["source"] = "ble-remote-write";
  engine_->publishEvent("characteristicWritten", payload);
}

NimbleEngine::NimbleEngine(DeviceState& state, CommandProtocol& protocol)
    : state_(state),
      protocol_(protocol),
      controlCallbacks_(this),
      dataCallbacks_(this),
      characteristicValue_("idle") {}

void NimbleEngine::begin(FramePublisher publisher) {
  publisher_ = std::move(publisher);
  NimBLEDevice::init(state_.deviceName.c_str());
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(state_.mtu);
  // Update deviceId to the actual BLE address assigned by the stack.
  state_.deviceId = NimBLEDevice::getAddress().toString().c_str();
  ensureServer();
  ensureControlService();
}

bool NimbleEngine::handleRawBleFrame(const String& rawFrame) {
  ParsedCommand command;
  String error;
  if (!protocol_.decode(rawFrame, command, error)) {
    JsonDocument payload;
    payload["error"] = error;
    publishEvent("bleDecodeError", payload);
    return false;
  }
  return handleCommand(command);
}

bool NimbleEngine::handleCommand(const ParsedCommand& command) {
  JsonDocument payload;
  state_.refreshTelemetry();
  state_.clearLastError();

  if (command.type == "handshake") {
    payload["deviceId"] = state_.deviceId;
    payload["address"] = state_.deviceId;  // deviceId is already the BLE address
    payload["architecture"] = state_.architecture;
    payload["transport"] = state_.controlTransport;
    publishResponse(command, true, "handshake-ok", payload);
    return true;
  }

  if (command.type == "setDeviceName") {
    const String nextName = command.payload["name"] | "nimble-hitl";
    state_.setDeviceName(nextName);
    resetRoles();
    server_ = nullptr;
    client_ = nullptr;
    controlService_ = nullptr;
    controlRxCharacteristic_ = nullptr;
    controlTxCharacteristic_ = nullptr;
    NimBLEDevice::deinit(true);
    vTaskDelay(pdMS_TO_TICKS(100));
    NimBLEDevice::init(state_.deviceName.c_str());
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    NimBLEDevice::setMTU(state_.mtu);
    state_.deviceId = NimBLEDevice::getAddress().toString().c_str();
    ensureServer();
    ensureControlService();
    payload["deviceName"] = state_.deviceName;
    publishResponse(command, true, "device-name-updated", payload);
    return true;
  }

  if (command.type == "configureServer") {
    ensureServer();
    const String serviceUuid =
        command.payload["serviceUuid"] | String(kDefaultServiceUuid);
    const String characteristicUuid =
        command.payload["characteristicUuid"] | String(kDefaultCharacteristicUuid);
    const String descriptorUuid =
        command.payload["descriptorUuid"] | String(kDefaultDescriptorUuid);

    service_ = server_->createService(serviceUuid.c_str());
    dataCharacteristic_ = service_->createCharacteristic(
        characteristicUuid.c_str(), NIMBLE_PROPERTY::READ |
                                        NIMBLE_PROPERTY::WRITE |
                                        NIMBLE_PROPERTY::NOTIFY);
    descriptor_ =
        dataCharacteristic_->createDescriptor(descriptorUuid.c_str(), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);
    descriptor_->setValue("nimble-hitl");
    dataCharacteristic_->setValue(characteristicValue_);
    dataCharacteristic_->setCallbacks(&dataCallbacks_);
    service_->start();
    state_.setRole("server");

    payload["serviceUuid"] = serviceUuid;
    payload["characteristicUuid"] = characteristicUuid;
    publishResponse(command, true, "server-configured", payload);
    return true;
  }

  if (command.type == "configureClient") {
    ensureClient();
    state_.setRole("client");
    payload["role"] = state_.activeRole;
    publishResponse(command, true, "client-configured", payload);
    return true;
  }

  if (command.type == "configureAdvertising") {
    setupAdvertising(command);
    payload["serviceUuid"] =
        command.payload["serviceUuid"] | String(kDefaultServiceUuid);
    payload["scanResponse"] = command.payload["scanResponse"] | true;
    publishResponse(command, true, "advertising-configured", payload);
    return true;
  }

  if (command.type == "startAdvertising") {
    if (advertising_ == nullptr) {
      setupAdvertising(command);
    }
    advertising_->start();
    payload["advertising"] = true;
    publishResponse(command, true, "advertising-started", payload);
    return true;
  }

  if (command.type == "stopAdvertising") {
    if (advertising_ != nullptr) {
      advertising_->stop();
    }
    payload["advertising"] = false;
    publishResponse(command, true, "advertising-stopped", payload);
    return true;
  }

  if (command.type == "setSecurity") {
    const bool bond = command.payload["bond"] | true;
    const bool mitm = command.payload["mitm"] | false;
    const bool secureConnection = command.payload["secureConnection"] | true;
    const uint32_t passkey = command.payload["passkey"] | 123456;
    NimBLEDevice::setSecurityAuth(bond, mitm, secureConnection);
    NimBLEDevice::setSecurityPasskey(passkey);
    payload["bond"] = bond;
    payload["mitm"] = mitm;
    payload["secureConnection"] = secureConnection;
    payload["passkey"] = passkey;
    publishResponse(command, true, "security-updated", payload);
    return true;
  }

  if (command.type == "setMtu") {
    const uint16_t mtu = command.payload["mtu"] | 185;
    NimBLEDevice::setMTU(mtu);
    state_.mtu = mtu;
    payload["mtu"] = mtu;
    publishResponse(command, true, "mtu-updated", payload);
    return true;
  }

  if (command.type == "swapRole") {
    resetRoles();
    if (state_.activeRole == "server") {
      ensureClient();
      state_.setRole("client");
    } else {
      ensureServer();
      state_.setRole("server");
    }
    payload["role"] = state_.activeRole;
    publishResponse(command, true, "role-swapped", payload);
    return true;
  }

  if (command.type == "connectPeer") {
    ensureClient();
    const String address = command.payload["address"] | "";
    if (address.isEmpty()) {
      publishError(command, "connectPeer requires an address payload");
      return false;
    }

    const bool connected = client_->connect(NimBLEAddress(address.c_str()));
    payload["address"] = address;
    payload["connected"] = connected;
    if (!connected) {
      publishError(command, "failed-to-connect-peer");
      return false;
    }
    remoteCharacteristic_ = nullptr;
    state_.setRole("client");
    publishResponse(command, true, "peer-connected", payload);
    return true;
  }

  if (command.type == "discoverAttributes") {
    if (client_ == nullptr || !client_->isConnected()) {
      publishError(command, "discoverAttributes requires an active connection");
      return false;
    }
    const String serviceUuid =
        command.payload["serviceUuid"] | String(kDefaultServiceUuid);
    const String characteristicUuid =
        command.payload["characteristicUuid"] | String(kDefaultCharacteristicUuid);

    NimBLERemoteService* remoteService =
        client_->getService(serviceUuid.c_str());
    if (remoteService == nullptr) {
      publishError(command, "discoverAttributes: service not found");
      return false;
    }

    // Force characteristic discovery refresh after connect; relying only on
    // cached state can miss the characteristic on some peers/iterations.
    remoteService->getCharacteristics(true);

    remoteCharacteristic_ =
        remoteService->getCharacteristic(characteristicUuid.c_str());
    if (remoteCharacteristic_ == nullptr) {
      payload["serviceUuid"] = serviceUuid;
      payload["characteristicUuid"] = characteristicUuid;
        const auto* characteristics = remoteService->getCharacteristics();
        payload["characteristicCount"] = characteristics == nullptr
          ? 0
          : static_cast<uint32_t>(characteristics->size());
      publishError(command, "discoverAttributes: characteristic not found");
      return false;
    }
    payload["serviceUuid"] = serviceUuid;
    payload["characteristicUuid"] = characteristicUuid;
    publishResponse(command, true, "attributes-discovered", payload);
    return true;
  }

  if (command.type == "subscribeCharacteristic") {
    if (client_ == nullptr || !client_->isConnected()) {
      publishError(command, "subscribeCharacteristic requires an active connection");
      return false;
    }
    if (remoteCharacteristic_ == nullptr) {
      publishError(command,
                   "subscribeCharacteristic requires discoverAttributes first");
      return false;
    }

    const bool notifications = command.payload["notifications"] | true;
    const bool response = command.payload["response"] | true;
    const bool subscribed = remoteCharacteristic_->subscribe(
        notifications,
        [this](NimBLERemoteCharacteristic* characteristic, uint8_t* data,
               size_t length, bool isNotify) {
          (void)characteristic;
          String value;
          value.reserve(length);
          for (size_t index = 0; index < length; ++index) {
            value += static_cast<char>(data[index]);
          }

          String valueHex;
          valueHex.reserve(length * 2);
          constexpr char kHex[] = "0123456789abcdef";
          for (size_t index = 0; index < length; ++index) {
            valueHex += kHex[(data[index] >> 4) & 0x0F];
            valueHex += kHex[data[index] & 0x0F];
          }

          JsonDocument eventPayload;
          eventPayload["value"] = value;
          eventPayload["valueHex"] = valueHex;
          eventPayload["length"] = length;
          eventPayload["mode"] = isNotify ? "notify" : "indicate";
          publishEvent("characteristicNotification", eventPayload);
        },
        response);

    payload["subscribed"] = subscribed;
    payload["notifications"] = notifications;
    if (!subscribed) {
      publishError(command, "failed-to-subscribe");
      return false;
    }
    publishResponse(command, true, "characteristic-subscribed", payload);
    return true;
  }

  if (command.type == "disconnectPeer") {
    if (client_ != nullptr && client_->isConnected()) {
      client_->disconnect();
      client_ = nullptr;
    }
    remoteCharacteristic_ = nullptr;
    payload["connected"] = false;
    publishResponse(command, true, "peer-disconnected", payload);
    return true;
  }

  if (command.type == "writeCharacteristic") {
    const String value = command.payload["value"] | "";
    characteristicValue_ = value;
    if (remoteCharacteristic_ != nullptr) {
      // Client path: write to the remote server characteristic over BLE.
      const bool ok = remoteCharacteristic_->writeValue(value.c_str(), true);
      payload["value"] = value;
      payload["remote"] = true;
      if (!ok) {
        publishError(command, "remote write failed");
        return false;
      }
    } else if (dataCharacteristic_ != nullptr) {
      // Server path: update local characteristic value.
      dataCharacteristic_->setValue(value);
      payload["value"] = value;
      payload["remote"] = false;
    } else {
      publishError(command, "no characteristic available — call configureServer or discoverAttributes first");
      return false;
    }
    publishResponse(command, true, "characteristic-written", payload);
    return true;
  }

  if (command.type == "readCharacteristic") {
    if (remoteCharacteristic_ != nullptr) {
      // Client path: read from the remote server characteristic over BLE.
      const std::string value = remoteCharacteristic_->readValue();
      payload["value"] = value.c_str();
      payload["remote"] = true;
    } else {
      // Server path: return the locally stored value.
      payload["value"] = characteristicValue_;
      payload["remote"] = false;
    }
    publishResponse(command, true, "characteristic-read", payload);
    return true;
  }

  if (command.type == "notifyCharacteristic") {
    characteristicValue_ = command.payload["value"] | "notify";
    if (dataCharacteristic_ != nullptr) {
      dataCharacteristic_->setValue(characteristicValue_);
      dataCharacteristic_->notify();
    }
    payload["value"] = characteristicValue_;
    publishResponse(command, true, "notification-sent", payload);
    return true;
  }

  if (command.type == "switchControlTransport") {
    const String nextTransport = command.payload["transport"] | "serial";
    if (nextTransport == "ble") {
      ensureControlService();
    }
    state_.setTransport(nextTransport);
    payload["transport"] = state_.controlTransport;
    publishResponse(command, true, "transport-updated", payload);
    return true;
  }

  if (command.type == "pollTelemetry") {
    payload["freeHeap"] = state_.freeHeap;
    payload["minimumFreeHeap"] = state_.minimumFreeHeap;
    payload["role"] = state_.activeRole;
    publishResponse(command, true, "telemetry-snapshot", payload);
    return true;
  }

  if (command.type == "runStressPass") {
    const bool ok = runStressPass(command);
    payload["iterations"] = command.payload["iterations"] | 100;
    publishResponse(command, ok, ok ? "stress-pass-complete" : "stress-pass-failed",
                    payload);
    return ok;
  }

  if (command.type == "captureDiagnostics") {
    state_.refreshTelemetry();
    state_.fillDiagnosticsPayload(payload.to<JsonObject>());
    publishResponse(command, true, "diagnostics-captured", payload);
    return true;
  }

  publishError(command, "unsupported-command");
  return false;
}

void NimbleEngine::publishToBle(const String& frame) {
  if (controlTxCharacteristic_ == nullptr || state_.controlTransport != "ble") {
    return;
  }

  controlTxCharacteristic_->setValue(frame.c_str());
  controlTxCharacteristic_->notify();
}

void NimbleEngine::loop() {}

void NimbleEngine::publishResponse(const ParsedCommand& command, bool ok,
                                   const String& message,
                                   const JsonDocument& payload) {
  publisher_(protocol_.encodeResponse(command.id, state_.deviceId, command.type, ok,
                                      message, payload));
}

void NimbleEngine::publishError(const ParsedCommand& command,
                                const String& message) {
  state_.setLastError(message);
  JsonDocument payload;
  payload["error"] = message;
  publishResponse(command, false, message, payload);
}

void NimbleEngine::publishEvent(const String& type,
                                const JsonDocument& payload) {
  publisher_(protocol_.encodeEvent(state_.deviceId, type, payload));
}

void NimbleEngine::ensureServer() {
  if (server_ == nullptr) {
    server_ = NimBLEDevice::createServer();
    server_->start();
  }
}

void NimbleEngine::ensureClient() {
  if (client_ == nullptr) {
    client_ = NimBLEDevice::createClient();
  }
}

void NimbleEngine::ensureControlService() {
  ensureServer();
  if (controlService_ != nullptr) {
    return;
  }

  controlService_ = server_->createService(kControlServiceUuid);
  controlRxCharacteristic_ = controlService_->createCharacteristic(
      kControlRxUuid, NIMBLE_PROPERTY::WRITE);
  controlTxCharacteristic_ = controlService_->createCharacteristic(
      kControlTxUuid, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  controlRxCharacteristic_->setCallbacks(&controlCallbacks_);
  controlTxCharacteristic_->setValue("ready");
  controlService_->start();
}

void NimbleEngine::resetRoles() {
  if (client_ != nullptr && client_->isConnected()) {
    client_->disconnect();
  }
  remoteCharacteristic_ = nullptr;
  if (advertising_ != nullptr) {
    advertising_->stop();
  }
  resetServerObjects();
  state_.setRole("idle");
}

void NimbleEngine::resetServerObjects() {
  if (server_ != nullptr && service_ != nullptr) {
    server_->removeService(service_, true);
  }
  if (server_ != nullptr && controlService_ != nullptr && controlService_ != service_) {
    server_->removeService(controlService_, true);
  }
  service_ = nullptr;
  dataCharacteristic_ = nullptr;
  descriptor_ = nullptr;
  advertising_ = nullptr;
  controlService_ = nullptr;
  controlRxCharacteristic_ = nullptr;
  controlTxCharacteristic_ = nullptr;
}

void NimbleEngine::setupAdvertising(const ParsedCommand& command) {
  ensureServer();
  ensureControlService();
  advertising_ = NimBLEDevice::getAdvertising();
  advertising_->reset();
  advertising_->setScanResponse(command.payload["scanResponse"] | true);
  const String serviceUuid =
      command.payload["serviceUuid"] | String(kDefaultServiceUuid);
  advertising_->setName(state_.deviceName.c_str());
  advertising_->addServiceUUID(serviceUuid.c_str());
}

bool NimbleEngine::runStressPass(const ParsedCommand& command) {
  const int iterations = command.payload["iterations"] | 100;
  const bool allowRoleSwap = command.payload["allowRoleSwap"] | true;
  const uint32_t seed = command.payload["seed"] | millis();
  randomSeed(seed);

  for (int index = 0; index < iterations; ++index) {
    const int action = random(0, 5);
    switch (action) {
      case 0:
        state_.mtu = random(23, 247);
        NimBLEDevice::setMTU(state_.mtu);
        break;
      case 1:
        if (advertising_ == nullptr) {
          ParsedCommand advertisingCommand;
          advertisingCommand.payload["scanResponse"] = true;
          setupAdvertising(advertisingCommand);
        }
        advertising_->start();
        break;
      case 2:
        if (advertising_ != nullptr) {
          advertising_->stop();
        }
        break;
      case 3:
        characteristicValue_ = String("stress-") + index;
        if (dataCharacteristic_ != nullptr) {
          dataCharacteristic_->setValue(characteristicValue_);
          dataCharacteristic_->notify();
        }
        break;
      case 4:
        if (allowRoleSwap) {
          state_.setRole(state_.activeRole == "server" ? "client" : "server");
        }
        break;
      default:
        break;
    }
    state_.refreshTelemetry();
    delay(2);
  }

  return true;
}

