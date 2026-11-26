/// BLE GATT 连接驱动 —— 移植自 v1.3.0 lib/src/core/services/ble_gatt_driver.dart
/// 针对 iOS/CoreBluetooth 精简：剔除 Linux/Web 分支，纯 BLE GATT。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'ble_uuids.dart';

/// 扫描到的设备端点。
class BleEndpoint {
  const BleEndpoint({
    required this.deviceId,
    required this.name,
    this.rssi,
    this.serviceUuids = const [],
    this.productId,
    this.registered,
  });

  final String deviceId;
  final String name;
  final int? rssi;
  final List<String> serviceUuids;
  final int? productId;
  final bool? registered;

  @override
  String toString() => '$name ($deviceId) rssi=$rssi';
}

/// 建立的连接，封装 GATT 读写/订阅。
class BleConnection {
  BleConnection({required this.deviceId, required this.deviceName});

  final String deviceId;
  final String deviceName;
  int mtu = 23;
  List<BleService> services = const [];

  final _connectionController = StreamController<bool>.broadcast();
  StreamSubscription<bool>? _connectionSubscription;
  Future<void> _writeTail = Future<void>.value();
  bool _disposed = false;

  Stream<bool> get connectionState => _connectionController.stream;
  bool get isDisposed => _disposed;

  Future<void> start() async {
    _connectionSubscription =
        UniversalBle.connectionStream(deviceId).listen((connected) {
      if (!_connectionController.isClosed) _connectionController.add(connected);
    }, onError: (Object e) {
      // 连接流错误不应使整个连接失败
    });
  }

  /// UUID 归一化比较：忽略大小写和连字符，并支持 16bit↔128bit 互换。
  static String _norm(String uuid) =>
      uuid.toLowerCase().replaceAll('-', '').replaceAll(' ', '');

  static bool _uuidEq(String a, String b) {
    final na = _norm(a);
    final nb = _norm(b);
    if (na == nb) return true;
    // 16bit UUID 补齐蓝牙基 UUID
    const base = '0000ffff00001000800000805f9b34fb';
    if (na.length == 4 && nb.length == 32) {
      return nb == base.replaceRange(4, 8, na);
    }
    if (nb.length == 4 && na.length == 32) {
      return na == base.replaceRange(4, 8, nb);
    }
    return false;
  }

  BleCharacteristic? findCharacteristic(String serviceUuid, String charUuid) {
    for (final service in services) {
      if (!_uuidEq(service.uuid, serviceUuid)) continue;
      for (final c in service.characteristics) {
        if (_uuidEq(c.uuid, charUuid)) return c;
      }
      // fallback: 同服务下任意 UUID 匹配（某些设备描述不一致）
      for (final c in service.characteristics) {
        if (_uuidEq(c.uuid, charUuid)) return c;
      }
    }
    return null;
  }

  Future<void> discoverServices() async {
    services = await UniversalBle.discoverServices(deviceId).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('service discovery timed out'),
    );
  }

  Future<StreamSubscription<Uint8List>> subscribe(
    String serviceUuid,
    String charUuid,
    void Function(Uint8List data) onData,
  ) async {
    final characteristic = findCharacteristic(serviceUuid, charUuid);
    if (characteristic == null) {
      throw StateError('Characteristic $charUuid not found');
    }
    await characteristic.notifications.subscribe().timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw TimeoutException('subscribe timeout: $charUuid'),
    );
    return characteristic.onValueReceived.listen((value) {
      onData(value);
    }, onError: (Object _) {});
  }

  Future<void> unsubscribe(String serviceUuid, String charUuid) async {
    final characteristic = findCharacteristic(serviceUuid, charUuid);
    if (characteristic == null) return;
    await characteristic.notifications.unsubscribe().timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
  }

  Future<void> write(
    String serviceUuid,
    String charUuid,
    Uint8List data, {
    required bool withResponse,
  }) async {
    final characteristic = findCharacteristic(serviceUuid, charUuid);
    if (characteristic == null) {
      throw StateError('Characteristic $charUuid not found');
    }
    final supportsWrite =
        characteristic.properties.contains(CharacteristicProperty.write);
    final supportsNoResponse = characteristic.properties.contains(
      CharacteristicProperty.writeWithoutResponse,
    );
    // 与源协议一致的 withResponse 降级逻辑
    final effectiveWithResponse = switch ((
      withResponse,
      supportsWrite,
      supportsNoResponse,
    )) {
      (true, true, _) => true,
      (true, false, true) => false,
      (false, _, true) => false,
      (false, true, false) => true,
      _ => throw StateError('Characteristic $charUuid does not support writing'),
    };
    final completer = Completer<void>();
    // 串行化写操作，避免并发写导致 GATT 错误
    _writeTail = _writeTail.then((_) async {
      if (_disposed) throw StateError('BLE connection disposed');
      await characteristic
          .write(data, withResponse: effectiveWithResponse)
          .timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('write timeout: $charUuid'),
      );
    }).then(
      (_) => completer.complete(),
      onError: (Object e, StackTrace st) => completer.completeError(e, st),
    );
    // 失败不污染后续排队写操作
    _writeTail = _writeTail.catchError((Object _) {});
    return completer.future;
  }

  Future<int> requestMtu(int desiredMtu) async {
    try {
      mtu = await UniversalBle.requestMtu(deviceId, desiredMtu).timeout(
        const Duration(seconds: 5),
      );
    } catch (_) {
      // 保持默认 23
    }
    return mtu;
  }

  int get maxWriteLength => mtu.clamp(23, 515) - 3;

  Future<void> dispose() async {
    _disposed = true;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    if (!_connectionController.isClosed) await _connectionController.close();
    try {
      await UniversalBle.disconnect(deviceId).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

/// BLE 扫描器 + 连接器。
class BleGattDriver {
  final _scanController = StreamController<BleEndpoint>.broadcast();
  final _scanResults = <String, BleEndpoint>{};
  StreamSubscription<BleDevice>? _scanSubscription;
  Timer? _scanStopTimer;

  Stream<BleEndpoint> get scanStream => _scanController.stream;
  List<BleEndpoint> get lastResults => _scanResults.values.toList(growable: false);

  Future<bool> isAvailable() async {
    try {
      final state = await UniversalBle.getBluetoothAvailabilityState();
      return state == AvailabilityState.poweredOn;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestPermissions() async {
    await UniversalBle.requestPermissions(withAndroidFineLocation: false);
  }

  /// 解析小米广播 service data，返回 (productId, registered)。
  static (int?, bool?) parseXiaomiAdvertisement(BleDevice device) {
    try {
      for (final entry in device.serviceData.entries) {
        final key = entry.key.toLowerCase().replaceAll('-', '');
        if (key != 'fe95' && key != '0000fe9500001000800000805f9b34fb') {
          continue;
        }
        final bytes = entry.value;
        if (bytes.length < 4) continue;
        final productId = bytes[2] | (bytes[3] << 8);
        final flag = bytes[0];
        final minSize = 5 +
            ((flag & 0x10) != 0 ? 6 : 0) +
            ((flag & 0x20) != 0 ? 1 : 0);
        final registered = bytes.length >= minSize && productId != 0
            ? (bytes[1] & 0x01) != 0
            : null;
        return (productId, registered);
      }
    } catch (_) {}
    return (null, null);
  }

  Future<void> startScan({
    List<String>? withServices,
    List<String>? withNamePrefixes,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await stopScan();
    _scanResults.clear();

    _scanSubscription = UniversalBle.scanStream.listen((device) {
      final name = device.name?.trim() ?? '';
      if (withNamePrefixes != null && withNamePrefixes.isNotEmpty) {
        final matches = withNamePrefixes.any(
          (p) => name.toLowerCase().startsWith(p.toLowerCase()),
        );
        if (!matches) return;
      }
      final (pdId, registered) = parseXiaomiAdvertisement(device);
      final endpoint = BleEndpoint(
        deviceId: device.deviceId,
        name: name.isEmpty ? 'Unknown device' : name,
        rssi: device.rssi,
        serviceUuids: List<String>.from(device.services),
        productId: pdId,
        registered: registered,
      );
      _scanResults[device.deviceId] = endpoint;
      _scanController.add(endpoint);
    }, onError: (Object e) {
      // 扫描流错误仅记录，不中断
    });

    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: withServices ?? []),
    );
    _scanStopTimer = Timer(timeout, () => unawaited(stopScan()));
  }

  Future<List<BleEndpoint>> stopScan() async {
    _scanStopTimer?.cancel();
    _scanStopTimer = null;
    final sub = _scanSubscription;
    if (sub == null) return lastResults;
    await sub.cancel();
    _scanSubscription = null;
    try {
      if (await UniversalBle.isScanning().timeout(const Duration(seconds: 2))) {
        await UniversalBle.stopScan().timeout(const Duration(seconds: 3));
      }
    } on TimeoutException catch (_) {}
    return lastResults;
  }

  /// 完整连接流程：连接 → 配对 → 服务发现 → 特征校验 → MTU。
  Future<BleConnection> connect(
    BleEndpoint endpoint, {
    required List<BleRequiredCharacteristic> requiredCharacteristics,
    int? desiredMtu,
    bool attemptPair = true,
  }) async {
    await stopScan();
    const connectTimeout = Duration(seconds: 12);

    // ★ 关键：先订阅连接状态，再发起连接（CoreBluetooth 事件可能早于 connect 返回）
    final connection = BleConnection(
      deviceId: endpoint.deviceId,
      deviceName: endpoint.name,
    );
    await connection.start();

    try {
      await UniversalBle.connect(endpoint.deviceId, timeout: connectTimeout)
          .timeout(connectTimeout, onTimeout: () {
        throw TimeoutException('BLE connect timed out');
      });
    } on TimeoutException {
      await connection.dispose();
      throw StateError(
        '连接超时：设备可能被其他主机占用或超出蓝牙范围（${endpoint.name}）',
      );
    } catch (e) {
      await connection.dispose();
      if (e is PlatformException) {
        throw StateError('BLE connect failed: ${e.code}: ${e.message}');
      }
      rethrow;
    }

    // 配对（可选，失败忽略）
    if (attemptPair) {
      try {
        await UniversalBle.pair(endpoint.deviceId).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    // 服务发现
    try {
      await connection.discoverServices();
    } catch (e) {
      await connection.dispose();
      rethrow;
    }

    // 必需特征校验
    final missing = requiredCharacteristics.where((required) {
      return connection.findCharacteristic(
            required.serviceUuid,
            required.characteristicUuid,
          ) ==
          null;
    }).toList();
    if (missing.isNotEmpty) {
      await connection.dispose();
      throw StateError(
        '缺少必需 BLE 特征：${missing.map((c) => c.characteristicUuid).join(', ')}',
      );
    }

    // MTU 协商
    if (desiredMtu != null && desiredMtu > 23) {
      await connection.requestMtu(desiredMtu);
    }

    return connection;
  }

  Future<void> dispose() async {
    await stopScan();
    await _scanController.close();
  }
}
