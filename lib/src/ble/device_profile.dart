/// 设备画像与识别 —— 移植自 v1.3.0 lib/src/device/core/device_profile.dart
/// ★ iOS 强制改写：所有原 preferredConnectType=spp 的设备改为 ble。
library;

import 'ble_uuids.dart';

enum DeviceKind { xiaomi, zepp, unknown }

class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.kind,
    required this.namePattern,
    required this.requiredCharacteristics,
    required this.desiredMtu,
    required this.attemptPair,
  });

  final String id;
  final DeviceKind kind;
  final RegExp namePattern;
  final List<BleRequiredCharacteristic> requiredCharacteristics;
  final int? desiredMtu;
  final bool attemptPair;

  bool matches(String name) => namePattern.hasMatch(name);
}

final _xiaomiProfile = DeviceProfile(
  id: 'xiaomi-vela',
  kind: DeviceKind.xiaomi,
  namePattern: RegExp(
    r'(Redmi Band|Redmi Watch|Xiaomi Smart Band|Xiaomi Watch|小米手环)',
    caseSensitive: false,
  ),
  requiredCharacteristics: xiaomiRequiredCharacteristics,
  desiredMtu: 517,
  attemptPair: true,
);

final _zeppProfile = DeviceProfile(
  id: 'zeppos',
  kind: DeviceKind.zepp,
  namePattern: RegExp(
    r'(Amazfit|Zepp|Mi Band 7|Amazfit Band 7|Amazfit GTR|Amazfit GTS|'
    r'Amazfit T-Rex|Amazfit Balance|Amazfit Active|Amazfit Cheetah|Amazfit Bip)',
    caseSensitive: false,
  ),
  requiredCharacteristics: zeppRequiredCharacteristics,
  // ZeppOS 从 MTU 23 开始，由协议编码器自行分片
  desiredMtu: null,
  // ZeppOS 自己走 endpoint 0x0082 authkey 握手，跳过系统配对
  attemptPair: false,
);

final List<DeviceProfile> deviceProfiles = [_xiaomiProfile, _zeppProfile];

/// 按设备名匹配画像；未知设备默认按小米 BLE 处理（iOS 无 SPP 可退）。
DeviceProfile profileFor(String name) {
  for (final profile in deviceProfiles) {
    if (profile.matches(name)) return profile;
  }
  return _xiaomiProfile;
}

DeviceKind kindFor(String name) => profileFor(name).kind;
