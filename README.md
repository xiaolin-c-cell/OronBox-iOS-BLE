# OronBox for iOS · 纯 BLE 版

基于上游 [OronCanopy/OronBox](https://github.com/OronCanopy/OronBox) **v1.3.0**（commit `68bb8ab`）蓝牙协议移植的 iOS 客户端。

## 特性

- **强制纯 BLE GATT**（iOS CoreBluetooth），完全移除 SPP/RFCOMM 路径
- 支持小米 VelaOS 与 Amazfit ZeppOS 全场景连接协议
- 保留上游 v1.3.0 的加密套件：AES-128-CTR / CCM / MiWear KDF / ZeppOS ECDH
- 保留 L1 帧协议与 CRC-16/ARC 校验
- 扫描过滤 FE95 / Zepp 1530 服务 UUID
- 内置加密自检、协议日志、测试帧发送

## 协议覆盖

| 场景 | 实现 |
|---|---|
| 扫描 | FE95 / Zepp 1530 服务过滤，RSSI，广播解析 productId/registered |
| 连接 | 12s 超时兜底，先订阅连接流再连接 |
| 配对 | 小米系统配对（失败忽略）；ZeppOS 跳过系统配对 |
| 服务发现 | 必需特征校验，16bit↔128bit UUID 归一化 |
| MTU | 小米目标 517；ZeppOS 保持 23 |
| 加密握手 | MiWear KDF + AES-CTR/CCM；ZeppOS endpoint 0x0082 ECDH |
| 帧协议 | L1 DATA/ACK/NAK/CMD + CRC-16/ARC |
| 断开 | 资源完整释放 |

详细协议见仓库根目录 `BLE_CONNECTION_PROTOCOL.md`。

## 构建 IPA

使用 GitHub Actions 的 `macos-15` runner：

1. 触发 `.github/workflows/build-ios-ble.yml`（`workflow_dispatch` 或 push 到 main）
2. workflow 自动执行 `flutter pub get` → `flutter analyze` → `flutter build ios --no-codesign` → ad-hoc 签名 → 打包 IPA
3. IPA 发布到 Releases 的 `ios-ble-v1.3.0` tag，同时上传为 Actions artifact

IPA 为 ad-hoc 签名，可通过 TrollStore / 巨魔 或企业签名工具侧载安装。

## 源码来源

协议代码移植自 v1.3.0 的以下文件：

- `lib/src/core/services/ble_gatt_driver.dart` — GATT 扫描/连接/MTU
- `lib/src/device/core/ble_transport.dart` — BLE 传输层
- `lib/src/device/xiaomi/protocol/crypto/miwear_crypto.dart` — 小米加密
- `lib/src/device/xiaomi/protocol/packet/l1_packet.dart` — L1 帧
- `lib/src/device/zeppos/crypto/zeppos_auth_crypto.dart` — ZeppOS 加密

为适配 iOS 编译器，剔除了桌面/语音/WASM 等重依赖，仅保留 `universal_ble` + `pointycastle` + `crypto`。

## 免责声明

本项目为技术研究用途，与小米、华米、OronCanopy 官方无关联。
