# OronBox for iOS — 全场景 BLE 连接协议

> 基于 `OronCanopy/OronBox` v1.3.0（tag `v1.3.0`，commit `68bb8ab`，2026-11-22）源码逆向梳理。
> 目标平台：**iOS（CoreBluetooth）**，强制纯 BLE GATT，**不依赖 SPP/RFCLASSIC**。
> 本协议覆盖扫描、识别、连接、配对、服务发现、MTU、分片重组、加密握手、保活、重连、断开、错误恢复全部场景。

---

## 1. 术语与范围

| 术语 | 含义 |
|---|---|
| BLE | Bluetooth Low Energy，GATT 架构 |
| SPP | Serial Port Profile，经典蓝牙 RFCOMM，**iOS 不支持，本项目禁用** |
| Central | iOS 手机（本 App） |
| Peripheral | 手环/手表（小米 VelaOS 或 Amazfit ZeppOS） |
| CCCD | Client Characteristic Configuration Descriptor，通知开关 |
| MTU | 单次 GATT 写/通知的最大协商字节数 |

**强制约束（iOS 端）：**
1. 所有 `ConnectType.spp` 分支在编译期剔除，扫描、连接、传输只保留 `ConnectType.ble`。
2. 不使用 `flutter_bluetooth_serial` 等 RFCOMM 通道；只用 `universal_ble`（iOS → CoreBluetooth）。
3. 连接超时统一 12s（CoreBluetooth 无原生 connect timeout，需外层兜底）。

---

## 2. 设备识别与 GATT 服务 UUID

### 2.1 小米 / VelaOS

| 项目 | UUID / 值 |
|---|---|
| 服务 UUID | `0000FE95-0000-1000-8000-00805F9B34FB` |
| 接收特征（Notify，手机读） | `0000005E-0000-1000-8000-00805F9B34FB` |
| 发送特征（Write，手机写） | `0000005F-0000-1000-8000-00805F9B34FB` |
| 默认写方式 | `writeWithoutResponse`（`withResponse=false`） |
| 广播 Service Data Key | `0xFE95`（或完整 128bit `0000fe9500001000800000805f9b34fb`） |

**广播解析规则（来自 `_parseXiaomiAdvertisement`）：**
```
serviceData[0xFE95] → bytes
  productId  = bytes[2] | (bytes[3] << 8)          // 小端
  flagByte   = bytes[0]
  minSize    = 5 + ((flag & 0x10) ? 6 : 0) + ((flag & 0x20) ? 1 : 0)
  registered = (bytes.length >= minSize && productId != 0)
               ? ((bytes[1] & 0x01) != 0) : null
```
`registered` 用于区分是否已在小米账号绑定；未注册设备走配对页面。

### 2.2 Amazfit / ZeppOS

| 项目 | UUID / 值 |
|---|---|
| 服务 UUID | `00001530-0000-3512-2118-0009AF100700` |
| 接收特征（Notify） | `00000017-0000-3512-2118-0009AF100700` |
| 发送特征（Write） | `00000016-0000-3512-2118-0009AF100700` |
| 默认写方式 | `writeWithResponse`（`withResponse=true`） |
| 认证端点 | `0x0082` |
| 经典蓝牙服务（仅识别，**iOS 禁用**） | `00000022-0000-3512-2118-0009AF100700` |

**关键差异：** ZeppOS 使用自己的 authkey 握手，**不做系统配对**（`bleAttemptPair=false`），且**不主动协商 MTU**（`bleDesiredMtu=null`，从 23 开始，由 Gadgetbridge 兼容的协议编码器自行分片）。小米设备默认 `bleAttemptPair=true`、目标 MTU=517。

### 2.3 名称匹配规则（设备画像）

| 设备 | 名称正则 |
|---|---|
| Redmi Band | `Redmi Band \w` |
| Redmi Watch | `Redmi Watch \w` |
| Xiaomi Smart Band Pro | `Xiaomi Smart Band \w\w? Pro .{4}` / `小米手环\w\w? Pro` |
| Xiaomi Smart Band | `Xiaomi Smart Band \w\w? ?\S{4}?` / `小米手环\w\w?` |
| Xiaomi Watch S | `Xiaomi Watch S\w(?: Pro)? (?:eSIM )?\S{4}` |
| ZeppOS | `Amazfit\|Zepp\|Mi Band 7\|Amazfit Band 7\|Amazfit GTR/GTS/T-Rex/Balance/Active/Cheetah/Bip` |

> ⚠️ **iOS 强制改写：** 上表中 `preferredConnectType=spp` 的小米设备（Redmi Band/Watch、Xiaomi Band/Watch S）在 iOS 上一律改为 `ble`，使用小米 BLE 特征对（5E/5F）。协议层用 L1/L2 重装帧承载，与 SPP 路径等价。

---

## 3. 全场景连接状态机

```
  ┌──────────┐  权限通过   ┌──────────┐  发现设备   ┌──────────┐
  │ Idle     │ ──────────▶ │ Scanning │ ──────────▶ │ Discovered│
  └──────────┘             └──────────┘             └────┬─────┘
        ▲                       │ 超时15s                 │ 选择设备
        │                       ▼                         ▼
        │                  ┌──────────┐            ┌──────────────┐
        │                  │ Idle     │            │ Connecting   │
        │                  └──────────┘            └──────┬───────┘
        │                                                 │ 12s 超时/失败
        │                                                 ▼
        │                                          ┌──────────────┐
        │                                          │ Failed/Retry │
        │                                          └──────┬───────┘
        │                                                 │ 平台连接成功
        │                                                 ▼
        │                           ┌────────────────────────────────┐
        │                           │ Pairing(可选) → DiscoverSvc    │
        │                           │ → VerifyChars → RequestMTU     │
        │                           └──────────────┬─────────────────┘
        │                                          │
        │                                          ▼
        │                                   ┌─────────────┐
        │                                   │ Auth        │
        │                                   │ (miwear /   │
        │                                   │  zeppos)    │
        │                                   └──────┬──────┘
        │                                          │
        │                                          ▼
        │                                   ┌─────────────┐
        └────────── disconnect ◀────────────│  Connected  │◀── reconnect
                                            └─────────────┘
```

### 场景 S1 — 扫描

1. **权限检查**（iOS）：`NSBluetoothAlwaysUsageDescription` 已在 Info.plist；调用 `UniversalBle.isAvailable()`，若为关闭态引导用户去设置。
2. **请求权限**：`UniversalBle.requestPermissions()`（iOS 13+ 自动弹窗）。
3. **启动扫描**：
   ```
   UniversalBle.startScan(ScanFilter(withServices: [FE95, 1530 服务 UUID]))
   ```
   - 名称前缀过滤：`withNamePrefixes`（可选）
   - 超时：15s 自动 `stopScan()`
   - 扫描结果去重：按 `deviceId` 存入 map，重复上报只更新
4. **广播字段采集**：`rssi`、`services`、`serviceData`；小米设备解析 `productId`/`registered`。

### 场景 S2 — 连接建立

1. `stopScan()` 先停止扫描（避免扫描与连接并发干扰）。
2. **先订阅连接状态流，再发起连接**（关键：某些 CoreBluetooth 后端连接事件早于 connect() 返回，晚订阅会丢失事件导致误判超时）。
3. `UniversalBle.connect(deviceId, timeout: 12s)`，外层再套 `.timeout(12s)` 兜底。
4. 超时提示："设备可能被其他主机占用或超出范围"。
5. iOS **不做** Android 的 `requestConnectionPriority(high)`。

### 场景 S3 — 配对

| 设备 | 策略 |
|---|---|
| 小米 | `UniversalBle.pair(deviceId)`，5s 超时，失败**忽略**（协议层 auth 不依赖系统配对） |
| ZeppOS | **跳过**系统配对（避免 `pair()` 挂起），走自己的 endpoint 0x0082 authkey 握手 |

### 场景 S4 — 服务发现与特征校验

1. `discoverServices()`（超时保护）。
2. 逐项检查必需的 characteristic（service UUID + characteristic UUID）是否存在；缺失则断开并抛出包含已发现服务清单的错误。
3. 特征 UUID 匹配支持**大小写与连字符归一化**，并兼容特征挂在同 service 不同 UUID 的 fallback（记录 warning）。

### 场景 S5 — MTU 协商

- 小米：目标 517，调用 `requestMtu(517)`，失败则保持默认 23。
- ZeppOS：**不协商**，保持 23。
- 有效写载荷：`clamp(mtu - 3, 20, 512)`。

### 场景 S6 — 通知订阅

1. 对接收特征（小米 5E / Zepp 17）调用 `subscribe()` 打开 CCCD。
2. 数据到达 → 计入下行流量 → 推入协议解析器。
3. 固件升级等独占操作时 `suspendProtocolNotifications()`，结束后 `resumeProtocolNotifications()`。

### 场景 S7 — 小米 MiWear 认证握手

1. **密钥派生** `kdfMiwear(secretKey, phoneNonce, watchNonce)`：
   ```
   initKey = phoneNonce(16B) || watchNonce(16B)
   hmacKey = HMAC-SHA256(initKey, secretKey)
   okm     = HKDF-like 扩展：3 轮 HMAC(hmacKey, prev || "miwear-auth" || counter)
   ```
   派生 64 字节 session key material。
2. **传输加密**：`AES-128-CTR`（key 16B, IV 16B）。
3. **消息认证**：`AES-128-CCM`（nonce 12B, AAD, tag 4B）。
4. authKey 为 32 个 hex 字符 → 16 字节。

### 场景 S8 — 小米 L1/L2 帧与 SAR 分片

**L1 帧格式（8 字节头 + payload）：**
```
| magic(2B)=0xA5A5 | type/frx(1B) | seq(1B) | length(2B LE) | crc16-arc(2B LE) | payload |
```
- `type`: 0=NAK, 1=ACK, 2=CMD, 3=DATA
- `frx`: bit 0x10
- CRC: CRC-16/ARC over payload

**L1 CMD 配置类型：**
| key | 含义 |
|---|---|
| 0x01 | version |
| 0x02 | MPS |
| 0x03 | txWin |
| 0x04 | sendTimeout |
| 0x05 | deviceType |
| 0x06 | deviceName |
| 0x07 | osVersion |

**L1 开始会话命令：** `cmdL1startReq=1` / `cmdL1startRsp=2` / `cmdL1stopReq=3` / `cmdL1stopRsp=4`。

**SAR 滑动窗口：**
- 本地发送窗口 `_localTxWin = 32`，远端初始 `txWin = 64`
- 每包有 seq，等待 ACK；超时 10s 重传
- 累积 ACK（`_rxCumAckSeq`）+ 单包 ACK 集合
- 命令队列（高优先级）与数据包队列分离

### 场景 S9 — ZeppOS 认证握手（endpoint 0x0082）

1. 生成 ECDH 密钥对 `createZeppOsAuthKeyPair()`。
2. 发送 `cmdPubKey=0x04`：
   ```
   payload = [0x04, 0x02, 0x00, 0x02] || publicKey(48B)   // 共 52B
   ```
3. 响应 `0x10 0x04 0x01 ...` → `remoteRandom(16B) || remotePublicKey(48B)`，长度 ≥ 67。
4. `completeZeppOsAuth(authKey, privateKey, publicKey, remotePublicKey)` → 得到 `authKeys`（含 sessionKey）。
5. 发送 `cmdSessionKey=0x05`：
   ```
   payload = [0x05] || AES-ECB(authKeySecret, remoteRandom)[16B]
                    || AES-ECB(sessionKey, remoteRandom)[16B]     // 共 33B
   ```
6. 等待成功响应，12s 超时。

### 场景 S10 — 保活与重连

- `connectionState` 流持续监听；`connected=false` 时关闭入站流，标记断开。
- 重连策略：指数退避（1s → 2s → 4s → 8s，上限 30s），最多 5 次。
- 重连前先 `dispose()` 旧连接，重新走 S2 → S6。
- 认证密钥缓存：同一设备 authKey 缓存，重连后跳过用户重新输入。

### 场景 S11 — 断开与资源释放

1. 取消所有订阅（`_valueSubscription`、`_characteristicSubscriptions`、`_connectionSubscription`）。
2. `UniversalBle.disconnect(deviceId)`（3s 超时忽略错误）。
3. 关闭 `StreamController`、流量计时器。
4. 从连接表移除。

---

## 4. 错误处理矩阵

| 场景 | 错误 | 处理 |
|---|---|---|
| 权限 | 蓝牙未授权 | 引导系统设置 |
| 扫描 | 15s 无结果 | 返回 Idle，提示靠近设备 |
| 连接 | 12s 超时 | 提示设备被占用/超范围，进入重试 |
| 连接 | `deviceNotFound` | 重新扫描后重试一次 |
| 发现服务 | 特征缺失 | 断开，列出已发现服务/特征 |
| MTU | 协商失败 | 保持 23，用 protocol 分片 |
| 配对 | pair 失败 | 忽略，继续协议层认证 |
| 认证 | 12s 超时 | 触发 AuthFailed，清理状态 |
| 传输 | write 超时 | 队列 continue，不让失败污染后续写 |
| 断开 | 连接流 error | 记录 warning，关闭入站流 |

---

## 5. iOS 强制纯 BLE 的改造清单

对照 v1.3.0 源码，以下为 iOS 构建必须修改点：

| 源码位置 | 改造 |
|---|---|
| `lib/src/device/core/connect_type.dart` | 保留枚举但 iOS 运行时只用 `.ble` |
| `lib/src/device/core/device_profile.dart` | 所有 `preferredConnectType=spp` 改为 `ble` |
| `lib/src/core/services/default_bluetooth_platform.dart` | iOS 构建移除 `_rfcomm` 注入与 SPP 分支 |
| `lib/src/core/services/ble_gatt_driver.dart` | 保留（iOS 路径无 Linux/Web 分支） |
| `lib/src/device/core/ble_transport.dart` | 保留 BLE 构造器，移除 `xiaomiBluetooth/zeppBluetooth` |
| `Info.plist` | 添加 `NSBluetoothAlwaysUsageDescription` |
| `Podfile` | 平台 iOS 13+，启用 `use_frameworks!` |

---

## 6. 协议数据来源（v1.3.0 源码索引）

| 协议内容 | 源文件 |
|---|---|
| GATT 扫描/连接/MTU/配对 | `lib/src/core/services/ble_gatt_driver.dart` |
| 平台抽象与连接管理 | `lib/src/device/core/bluetooth_platform.dart`, `lib/src/core/services/default_bluetooth_platform.dart` |
| BLE 传输层 | `lib/src/device/core/ble_transport.dart` |
| 设备画像/名称规则 | `lib/src/device/core/device_profile.dart` |
| 小米加密（CTR/CCM/KDF） | `lib/src/device/xiaomi/protocol/crypto/miwear_crypto.dart` |
| 小米 L1 帧 | `lib/src/device/xiaomi/protocol/packet/l1_packet.dart` |
| 小米 L1 CMD | `lib/src/device/xiaomi/protocol/packet/l1cmd_packet.dart` |
| 小米 SAR 分片 | `lib/src/device/xiaomi/protocol/transport/xiaomi_sar_controller.dart` |
| ZeppOS 认证 | `lib/src/device/zeppos/systems/zeppos_auth_system.dart`, `zeppos_auth_crypto.dart` |

---

*文档版本：1.0 · 生成时间：2026-11-26 · 基于 OronBox v1.3.0 源码*
