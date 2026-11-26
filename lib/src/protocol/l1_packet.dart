/// 小米 L1 帧协议 —— 移植自 v1.3.0
/// lib/src/device/xiaomi/protocol/packet/l1_packet.dart
library;

import 'dart:typed_data';

enum L1DataType {
  nak(0),
  ack(1),
  cmd(2),
  data(3);

  const L1DataType(this.value);
  final int value;

  static L1DataType fromValue(int value) => switch (value) {
    0 => L1DataType.nak,
    1 => L1DataType.ack,
    2 => L1DataType.cmd,
    3 => L1DataType.data,
    _ => throw L1PacketException('Invalid L1 data type: $value'),
  };
}

class L1PacketException implements Exception {
  const L1PacketException(this.message);
  final String message;
  @override
  String toString() => message;
}

class L1Packet {
  L1Packet({
    required this.pktType,
    required this.frx,
    required this.seq,
    required this.payload,
  })  : length = payload.length,
        crc = _crc16Arc(payload);

  static const int magic = 0xA5A5;
  static const int typeMask = 0x0F;
  static const int frxMask = 0x10;

  final L1DataType pktType;
  final bool frx;
  final int seq;
  final int length;
  final int crc;
  final Uint8List payload;

  Uint8List toBytes() {
    final out = BytesBuilder()
      ..addByte(magic & 0xFF)
      ..addByte((magic >> 8) & 0xFF)
      ..addByte(_packTypeFrx(pktType, frx))
      ..addByte(seq & 0xFF)
      ..addByte(length & 0xFF)
      ..addByte((length >> 8) & 0xFF)
      ..addByte(crc & 0xFF)
      ..addByte((crc >> 8) & 0xFF)
      ..add(payload);
    return out.toBytes();
  }

  static L1Packet fromBytes(Uint8List buf) {
    if (buf.length < 8) throw L1PacketException('L1 packet too short');
    final foundMagic = buf[0] | (buf[1] << 8);
    if (foundMagic != magic) throw L1PacketException('Bad L1 magic');
    final (pktType, frx) = _unpackTypeFrx(buf[2]);
    final seq = buf[3];
    final length = buf[4] | (buf[5] << 8);
    final declaredCrc = buf[6] | (buf[7] << 8);
    if (buf.length < 8 + length) {
      throw L1PacketException('L1 length mismatch');
    }
    final payload = Uint8List.sublistView(buf, 8, 8 + length);
    if (declaredCrc != _crc16Arc(payload)) {
      throw L1PacketException('L1 CRC mismatch');
    }
    return L1Packet(pktType: pktType, frx: frx, seq: seq, payload: payload);
  }

  static int _packTypeFrx(L1DataType type, bool frx) {
    var b = type.value & typeMask;
    if (frx) b |= frxMask;
    return b;
  }

  static (L1DataType, bool) _unpackTypeFrx(int byte) =>
      (L1DataType.fromValue(byte & typeMask), (byte & frxMask) != 0);

  /// CRC-16/ARC：poly=0x8005, init=0x0000, refin/refout=true。
  static int _crc16Arc(Uint8List data) {
    var crc = 0;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc & 0xFFFF;
  }
}
