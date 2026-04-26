# LocalLink

LocalLink 是一个多端局域网通信项目，目标是在 macOS、iPhone、Android、Windows 设备之间完成本地网络发现、配对、文本发送、图片发送和文件传输。

## 项目结构

```text
apple/
  common/LocalLinkCore/           Apple 端共享 Swift 核心代码
  tests/LocalLinkCoreSmokeTests/  Apple 共享核心的冒烟测试
  ios/                            iPhone SwiftUI 应用源码
  macos/                          macOS SwiftUI 应用源码和构建脚本
  Package.swift                   Apple/Swift 构建配置
  project.yml                     XcodeGen 配置
  LocalLink.xcodeproj/            可直接用 Xcode 打开的 iPhone 工程
  dist/                           macOS 构建产物，生成后不提交
android/                          Android Kotlin 原生项目
windows/                          Windows WPF/.NET 原生项目
README.md                         项目总说明
```

## 架构说明

- Apple 端共享 `apple/common/LocalLinkCore`，macOS 和 iPhone 都使用这份 Swift 核心代码。
- Android 是独立 Kotlin/Android 项目，不由 Swift 生成，但实现同一套 LocalLink 通信协议。
- Windows 是独立 C#/WPF 项目，也不引用 Swift core，但实现同一套 LocalLink 通信协议。
- 三端协议保持一致：局域网发现、配对码确认、加密会话、文本帧、文件分片和传输完成确认。

## macOS 运行

在仓库根目录运行：

```sh
./apple/macos/build_and_run.sh
```

脚本会构建 macOS 应用并生成：

```text
apple/dist/LocalLink.app
```

可以直接双击这个 `.app`，也可以把它拖到 `/Applications`。

快速验证 macOS app 能启动：

```sh
./apple/macos/build_and_run.sh --verify
```

## iPhone 安装

在 macOS 上打开 Xcode 工程：

```sh
open apple/LocalLink.xcodeproj
```

然后在 Xcode 中：

1. 选择 `LocalLinkiOS` scheme。
2. 连接 iPhone，并在手机上信任这台 Mac。
3. 选择 iPhone 作为运行目标。
4. 在 Signing & Capabilities 里选择自己的 Apple ID team。
5. 如果 bundle identifier 冲突，把它改成类似 `com.<yourname>.LocalLink`。
6. 点击 Run，把 app 安装到 iPhone。

## Apple 核心测试

```sh
cd apple
swift run LocalLinkCoreSmokeTests
```

这个测试会快速检查帧编码解码、配对码、加密解密、信任设备存储、消息/传输记录和文件分片组装。

## Android 打开和检查

用 Android Studio 打开：

```sh
open android
```

命令行检查 Android Gradle 项目：

```sh
gradle -p android tasks
```

运行到 Android 手机时，需要手机和其他设备在同一个 Wi-Fi/LAN，并允许系统提示的本地网络或附近设备权限。

## Windows 运行

在 Windows 机器上使用 Visual Studio 2022 或 .NET 8 SDK：

```powershell
cd windows\LocalLink.Windows
dotnet restore
dotnet run
```

如果 Windows Firewall 弹出提示，允许 private network 访问。Windows 端使用 mDNS/Bonjour 兼容发现和直接 TCP 会话进行传输。

## 配对和传输流程

1. 在两台设备上打开 LocalLink。
2. 确保设备连接到同一个 Wi-Fi/LAN。
3. 在 Nearby 列表中选择另一台设备。
4. 从任意一端发起配对。
5. 两端确认相同的 6 位配对码。
6. 配对成功后发送文本、图片或文件。

## 常见问题

- 如果看不到附近设备，先确认两台设备在同一局域网，并允许本地网络、防火墙或附近设备权限。
- 如果 iPhone 无法安装，检查 Xcode 签名 team、bundle identifier 和手机信任状态。
- 如果 Android Studio 无法同步，检查 Android SDK 和 JDK 17。
- 如果 Windows 无法发现设备，确认防火墙允许 private network。
