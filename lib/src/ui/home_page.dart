import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import '../ble/ble_connection.dart';
import '../ble/ble_uuids.dart';
import '../ble/device_profile.dart';
import '../protocol/l1_packet.dart';
import '../protocol/miwear_crypto.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BleGattDriver _driver = BleGattDriver();
  final List<BleEndpoint> _devices = [];
  final List<String> _logs = [];
  StreamSubscription<BleEndpoint>? _scanSub;
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<bool>? _connSub;

  bool _available = false;
  bool _scanning = false;
  bool _connecting = false;
  BleConnection? _connection;
  DeviceProfile? _profile;
  String? _connectedDeviceId;
  int _rxBytes = 0;
  int _txBytes = 0;
  int _mtu = 23;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _driver.requestPermissions();
    final available = await _driver.isAvailable();
    if (mounted) setState(() => _available = available);
    _log('蓝牙状态：${available ? "已开启" : "不可用/已关闭"}');
    if (!available) _log('请在系统设置中开启蓝牙后重试');
  }

  void _log(String msg) {
    final ts = DateTime.now().toLocal().toString().substring(11, 19);
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[$ts] $msg');
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _devices.clear();
      _scanning = true;
    });
    _log('开始扫描 BLE 设备（FE95 / Zepp 1530）…');
    await _scanSub?.cancel();
    _scanSub = _driver.scanStream.listen((endpoint) {
      if (!mounted) return;
      setState(() {
        final idx = _devices.indexWhere((d) => d.deviceId == endpoint.deviceId);
        if (idx >= 0) {
          _devices[idx] = endpoint;
        } else {
          _devices.add(endpoint);
        }
      });
    });
    try {
      await _driver.startScan(
        withServices: allBleServiceUuids,
        timeout: const Duration(seconds: 15),
      );
      _log('扫描已启动，15 秒后自动停止');
    } catch (e) {
      _log('扫描失败：$e');
      if (mounted) setState(() => _scanning = false);
    }
    // 15s 后更新扫描状态
    Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _stopScan() async {
    await _driver.stopScan();
    if (mounted) setState(() => _scanning = false);
    _log('扫描已停止，共发现 ${_devices.length} 台设备');
  }

  Future<void> _connect(BleEndpoint endpoint) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final profile = profileFor(endpoint.name);
    _log('连接 ${endpoint.name} [${profile.id}] …');
    _log('  MTU 目标=${profile.desiredMtu ?? "23(不协商)"}, 系统配对=${profile.attemptPair}');

    try {
      final conn = await _driver.connect(
        endpoint,
        requiredCharacteristics: profile.requiredCharacteristics,
        desiredMtu: profile.desiredMtu,
        attemptPair: profile.attemptPair,
      );

      // 订阅接收特征
      final readChar = profile.requiredCharacteristics.first;
      _dataSub = await conn.subscribe(
        readChar.serviceUuid,
        readChar.characteristicUuid,
        (data) {
          _rxBytes += data.length;
          _log('◀ 收到 ${data.length} 字节: ${_hexPreview(data)}');
        },
      );
      _connSub = conn.connectionState.listen((connected) {
        if (!connected) {
          _log('⚠ 设备断开连接');
          _cleanupConnection();
        }
      });

      if (mounted) {
        setState(() {
          _connection = conn;
          _profile = profile;
          _connectedDeviceId = endpoint.deviceId;
          _mtu = conn.mtu;
          _connecting = false;
        });
      }
      _log('✅ 连接就绪，MTU=$_mtu，可写载荷=${conn.maxWriteLength} 字节');
      _log('设备类型：${profile.kind == DeviceKind.zepp ? "ZeppOS（走 endpoint 0x0082 authkey 握手）" : "小米 VelaOS（走 MiWear AES-CTR/CCM + L1/SAR）"}');
    } catch (e) {
      _log('❌ 连接失败：$e');
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    _log('主动断开连接…');
    _cleanupConnection();
  }

  void _cleanupConnection() {
    _dataSub?.cancel();
    _dataSub = null;
    _connSub?.cancel();
    _connSub = null;
    final conn = _connection;
    _connection = null;
    _connectedDeviceId = null;
    if (mounted) {
      setState(() {
        _connection = null;
        _connectedDeviceId = null;
      });
    }
    unawaited(conn?.dispose());
  }

  Future<void> _sendTest() async {
    final conn = _connection;
    final profile = _profile;
    if (conn == null || profile == null) {
      _log('请先连接设备');
      return;
    }
    final writeChar = profile.requiredCharacteristics.last;
    // 构造一个 L1 DATA 测试帧
    final frame = L1Packet(
      pktType: L1DataType.data,
      frx: false,
      seq: 1,
      payload: Uint8List.fromList('HELLO-ORONBOX'.codeUnits),
    ).toBytes();
    try {
      await conn.write(
        writeChar.serviceUuid,
        writeChar.characteristicUuid,
        frame,
        withResponse: profile.kind == DeviceKind.zepp,
      );
      _txBytes += frame.length;
      _log('▶ 已发送 L1 DATA 帧 ${frame.length} 字节: ${_hexPreview(frame)}');
    } catch (e) {
      _log('发送失败：$e');
    }
  }

  void _runCryptoSelfTest() {
    _log('── 加密套件自检 ──');
    try {
      final key = Uint8List.fromList(List.generate(16, (i) => i));
      final iv = Uint8List.fromList(List.generate(16, (i) => i + 100));
      final plain = Uint8List.fromList('OronBox-BLE-Test'.codeUnits);
      final ct = aes128CtrCrypt(key, iv, plain);
      final pt = aes128CtrCrypt(key, iv, ct);
      final ok = String.fromCharCodes(pt) == 'OronBox-BLE-Test';
      _log('AES-128-CTR 加解密往返：${ok ? "✅ 通过" : "❌ 失败"}');

      final phoneNonce = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final watchNonce = Uint8List.fromList(List.generate(16, (i) => i + 17));
      final okm = kdfMiwear(key, phoneNonce, watchNonce);
      _log('MiWear KDF 派生：✅ 得到 ${okm.length} 字节会话密钥材料');
      _log('  preview=${_hexPreview(okm.sublist(0, 8))}');
    } catch (e) {
      _log('加密自检失败：$e');
    }
  }

  String _hexPreview(Uint8List data, [int max = 16]) {
    final take = data.length > max ? max : data.length;
    final hex = data
        .sublist(0, take)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return data.length > max ? '$hex …' : hex;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    _connection?.dispose();
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connection != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OronBox for iOS · 纯 BLE'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.shield_outlined),
            tooltip: '加密自检',
            onPressed: _runCryptoSelfTest,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBanner(connected),
          _buildActionBar(connected),
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(icon: Icon(Icons.devices), text: '设备'),
                      Tab(icon: Icon(Icons.article_outlined), text: '协议日志'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildDeviceList(),
                        _buildLogView(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(bool connected) {
    Color color;
    String text;
    if (connected) {
      color = Colors.green.shade700;
      text = '已连接 · MTU $_mtu · ↑$_txBytes ↓$_rxBytes 字节';
    } else if (_connecting) {
      color = Colors.orange.shade700;
      text = '正在连接…';
    } else if (_available) {
      color = Colors.blue.shade700;
      text = _scanning ? '扫描中… 发现 ${_devices.length} 台' : '蓝牙就绪 · 点击扫描';
    } else {
      color = Colors.grey.shade700;
      text = '蓝牙不可用';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      color: color,
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildActionBar(bool connected) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _connecting
                  ? null
                  : (_scanning ? _stopScan : _startScan),
              icon: Icon(_scanning ? Icons.stop : Icons.search),
              label: Text(_scanning ? '停止扫描' : '扫描设备'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: connected ? _disconnect : null,
              icon: const Icon(Icons.link_off),
              label: const Text('断开'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: connected ? _sendTest : null,
              icon: const Icon(Icons.send),
              label: const Text('测试帧'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    if (_devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('暂无设备，点击「扫描设备」开始'),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _devices.length,
      itemBuilder: (context, index) {
        final d = _devices[index];
        final profile = profileFor(d.name);
        final isConnected = d.deviceId == _connectedDeviceId;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: profile.kind == DeviceKind.zepp
                  ? Colors.deepPurple.shade100
                  : Colors.blue.shade100,
              child: Icon(
                profile.kind == DeviceKind.zepp
                    ? Icons.watch
                    : Icons.smartband,
                color: profile.kind == DeviceKind.zepp
                    ? Colors.deepPurple
                    : Colors.blue,
              ),
            ),
            title: Text(
              d.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${profile.id} · ${d.productId != null ? "PID=${d.productId}" : "未知PID"}'
              '${d.registered != null ? " · ${d.registered! ? "已绑定" : "未绑定"}" : ""}'
              ' · RSSI ${d.rssi ?? "?"}',
            ),
            trailing: isConnected
                ? const Icon(Icons.check_circle, color: Colors.green)
                : const Icon(Icons.chevron_right),
            onTap: isConnected ? null : () => _connect(d),
          ),
        );
      },
    );
  }

  Widget _buildLogView() {
    if (_logs.isEmpty) {
      return const Center(child: Text('协议日志将在此显示'));
    }
    return ListView.builder(
      itemCount: _logs.length,
      itemBuilder: (context, index) {
        final line = _logs[index];
        Color? color;
        if (line.contains('✅') || line.contains('通过')) color = Colors.green.shade700;
        if (line.contains('❌') || line.contains('失败')) color = Colors.red.shade700;
        if (line.contains('⚠')) color = Colors.orange.shade700;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Text(
            line,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: color,
            ),
          ),
        );
      },
    );
  }
}
