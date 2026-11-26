/// GATT UUID 定义 —— 移植自 OronBox v1.3.0
/// lib/src/device/core/ble_requirement.dart
library;

class BleRequiredCharacteristic {
  const BleRequiredCharacteristic({
    required this.serviceUuid,
    required this.characteristicUuid,
    this.label,
  });

  final String serviceUuid;
  final String characteristicUuid;
  final String? label;

  @override
  String toString() => label ?? characteristicUuid;
}

// ── 小米 / VelaOS ──────────────────────────────────────────────
const String xiaomiServiceUuid = '0000fe95-0000-1000-8000-00805f9b34fb';
const String xiaomiRecvCharUuid = '0000005e-0000-1000-8000-00805f9b34fb';
const String xiaomiSentCharUuid = '0000005f-0000-1000-8000-00805f9b34fb';

const List<BleRequiredCharacteristic> xiaomiRequiredCharacteristics = [
  BleRequiredCharacteristic(
    serviceUuid: xiaomiServiceUuid,
    characteristicUuid: xiaomiRecvCharUuid,
    label: 'xiaomi recv',
  ),
  BleRequiredCharacteristic(
    serviceUuid: xiaomiServiceUuid,
    characteristicUuid: xiaomiSentCharUuid,
    label: 'xiaomi sent',
  ),
];

// ── Amazfit / ZeppOS ───────────────────────────────────────────
const String zeppServiceUuid = '00001530-0000-3512-2118-0009af100700';
const String zeppRecvCharUuid = '00000017-0000-3512-2118-0009af100700';
const String zeppSentCharUuid = '00000016-0000-3512-2118-0009af100700';

const List<BleRequiredCharacteristic> zeppRequiredCharacteristics = [
  BleRequiredCharacteristic(
    serviceUuid: zeppServiceUuid,
    characteristicUuid: zeppRecvCharUuid,
    label: 'zeppos chunked 2021 read',
  ),
  BleRequiredCharacteristic(
    serviceUuid: zeppServiceUuid,
    characteristicUuid: zeppSentCharUuid,
    label: 'zeppos chunked 2021 write',
  ),
];

/// iOS 纯 BLE：扫描时按这两组服务 UUID 过滤。
const List<String> allBleServiceUuids = [
  xiaomiServiceUuid,
  zeppServiceUuid,
];
