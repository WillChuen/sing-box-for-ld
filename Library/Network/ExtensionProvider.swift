import Foundation
import Libbox
import NetworkExtension
#if os(iOS)
    import WidgetKit
#endif
#if os(macOS)
    import CoreLocation
#endif

/// 定义一个名为 ExtensionProvider 的开放类，继承自 NEPacketTunnelProvider。
/// open 修饰符表示此类可以在其他模块中被继承和重写。
/// NEPacketTunnelProvider 是 NetworkExtension 框架中的类，用于实现基于数据包的 VPN 隧道。
open class ExtensionProvider: NEPacketTunnelProvider {
    
    /// 声明一个公开的可选字符串属性 username，初始值为 nil。
    /// 用于存储当前用户的用户名，可能用于认证或日志记录。
    public var username: String? = nil
    
    /// 声明一个私有的隐式解包可选类型属性 commandServer，类型为 LibboxCommandServer。
    /// 用于处理命令和记录日志。隐式解包表示它会在使用前被初始化。
    private var commandServer: LibboxCommandServer!
    
    /// 声明一个私有的隐式解包可选类型属性 boxService，类型为 LibboxBoxService。
    /// 表示 VPN 服务的核心实现。
    private var boxService: LibboxBoxService!
    
    /// 系统代理是否可用
    private var systemProxyAvailable = false
    
    /// 系统代理是否已启用
    private var systemProxyEnabled = false
    
    /// 用于处理平台特定的接口和功能
    private var platformInterface: ExtensionPlatformInterface!

    /// 重写父类的 startTunnel 方法，用于启动 VPN 隧道。
    /// 在系统中打开VPN开关 系统会自动调用该方法
    override open func startTunnel(options _: [String: NSObject]?) async throws {
        // 调用 LibboxClearServiceError() 函数清除之前可能存在的服务错误
        LibboxClearServiceError()
        // 创建一个 LibboxSetupOptions 实例，用于配置 Libbox 服务。
        let options = LibboxSetupOptions()
        options.basePath = FilePath.sharedDirectory.relativePath
        options.workingPath = FilePath.workingDirectory.relativePath
        options.tempPath = FilePath.cacheDirectory.relativePath
        var error: NSError?
        #if os(tvOS)
            options.isTVOS = true
        #endif
        if let username {
            options.username = username
        }
        // 调用 LibboxSetup 函数初始化 Libbox 服务，传入配置选项和错误指针
        LibboxSetup(options, &error)
        if let error {
            writeFatalError("(packet-tunnel) error: setup service: \(error.localizedDescription)")
            return
        }
        // 调用 LibboxRedirectStderr 函数将标准错误输出重定向到指定的日志文件。
        // 日志文件位于缓存目录中，名为 "stderr.log"。
        LibboxRedirectStderr(FilePath.cacheDirectory.appendingPathComponent("stderr.log").relativePath, &error)
        if let error {
            writeFatalError("(packet-tunnel) redirect stderr error: \(error.localizedDescription)")
            return
        }
        
        // 异步调用 LibboxSetMemoryLimit 函数设置内存限制。
        // 如果用户选择忽略内存限制，则传入 false；否则传入 true。
        await LibboxSetMemoryLimit(!SharedPreferences.ignoreMemoryLimit.get())

        // 检查 platformInterface 是否为 nil：
        if platformInterface == nil {
            platformInterface = ExtensionPlatformInterface(self)
        }
        
        // 异步创建一个新的命令服务器实例，传入平台接口和最大日志行数作为参数。
        commandServer = await LibboxNewCommandServer(platformInterface, Int32(SharedPreferences.maxLogLines.get()))
        //
        do {
            // 尝试启动命令服务器
            try commandServer.start()
        } catch {
            writeFatalError("(packet-tunnel): log server start error: \(error.localizedDescription)")
            return
        }
        //
        writeMessage("(packet-tunnel): Here I stand")
        // 异步调用 startService 方法启动 VPN 服务。
        await startService()
        #if os(iOS)
        // 重新加载控制中心中的特定控件。这可能是为了更新 VPN 状态显示
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }
    
    /// 定义一个名为 writeMessage 的方法，接受一个字符串参数 message。
    /// 此方法用于将消息写入日志。
    func writeMessage(_ message: String) {
        if let commandServer {
            commandServer.writeMessage(message)
        }
    }

    /// 定义一个公开方法 writeFatalError，接受一个字符串参数 message。
    /// 用于记录致命错误并终止隧道。
    public func writeFatalError(_ message: String) {
        #if DEBUG
            NSLog(message)
        #endif
        // 调用 writeMessage 方法将错误消息写入日志。
        writeMessage(message)
        var error: NSError?
        // 调用 LibboxWriteServiceError 函数记录服务错误，传入错误消息和错误指针。
        LibboxWriteServiceError(message, &error)
        // 调用 cancelTunnelWithError 方法终止隧道，传入 nil 表示不指定特定错误。
        cancelTunnelWithError(nil)
    }
    
    /// 定义一个私有的异步方法 startService，用于启动 VPN 服务。
    private func startService() async {
        // 声明一个可选的 Profile 类型变量 profile。
        let profile: Profile?
        do {
            // 使用 SharedPreferences.selectedProfileID.get() 获取用户选择的配置文件 ID。
            profile = try await ProfileManager.get(Int64(SharedPreferences.selectedProfileID.get()))
        } catch {
            writeFatalError("(packet-tunnel) error: read selected profile: \(error.localizedDescription)")
            return
        }
        guard let profile else {
            writeFatalError("(packet-tunnel) error: missing selected profile")
            return
        }
        // 声明一个 String 类型变量 configContent，用于存储配置文件内容。
        let configContent: String
        do {
            // 调用 profile.read() 读取内容。
            configContent = try profile.read()
        } catch {
            writeFatalError("(packet-tunnel) error: read config file \(profile.path): \(error.localizedDescription)")
            return
        }
        // 调用 LibboxNewService 函数创建新的服务实例，传入配置内容、平台接口和错误指针。
        var error: NSError?
        let service = LibboxNewService(configContent, platformInterface, &error)
        if let error {
            writeFatalError("(packet-tunnel) error: create service: \(error.localizedDescription)")
            return
        }
        guard let service else {
            return
        }
        do {
            // 调用 service.start() 启动服务
            try service.start()
        } catch {
            writeFatalError("(packet-tunnel) error: start service: \(error.localizedDescription)")
            return
        }
        // 将服务实例设置给命令服务器，以便它可以与服务交互。
        commandServer.setService(service)
        // 将服务实例保存到 boxService 属性中，以便后续使用。
        boxService = service
        #if os(macOS)
        // 异步设置用户启动标志为 true，表示服务是由用户启动的。
            await SharedPreferences.startedByUser.set(true)
        // 检查服务是否需要 WiFi 状态信息。
            if service.needWIFIState() {
                // 如果不使用系统扩展（可能是使用应用扩展）：
                if !Variant.useSystemExtension {
                    locationManager = CLLocationManager()
                    locationDelegate = stubLocationDelegate(boxService)
                    locationManager?.delegate = locationDelegate
                    locationManager?.requestLocation()
                } else {
                    commandServer.writeMessage("(packet-tunnel) WIFI SSID and BSSID information is not currently available in the standalone version of SFM. We are working on resolving this issue.")
                }
            }
        /* 关于为什么需要使用 CLLocationManager 的注释：
         在较新版本的iOS和macOS中，Apple出于隐私考虑限制了直接获取WiFi信息的API。获取WiFi的SSID和BSSID需要以下权限：
         定位权限：iOS/macOS要求应用必须有定位权限才能访问WiFi信息
         特定权限声明：需要在Info.plist中声明特定用途
         代码使用CLLocationManager不是真正需要地理位置信息，而是作为获取WiFi信息的间接方式：
         当应用获得定位权限后，系统允许它访问当前连接的WiFi信息
         locationManagerDidChangeAuthorization方法被调用时，执行boxService.updateWIFIState()更新WiFi状态
         VPN服务使用这些信息来应用网络特定的规则
         */
        #endif
    }

    #if os(macOS)

        private var locationManager: CLLocationManager?
        private var locationDelegate: stubLocationDelegate?

        class stubLocationDelegate: NSObject, CLLocationManagerDelegate {
            private unowned let boxService: LibboxBoxService
            init(_ boxService: LibboxBoxService) {
                self.boxService = boxService
            }

            func locationManagerDidChangeAuthorization(_: CLLocationManager) {
                boxService.updateWIFIState()
            }

            func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}

            func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
        }

    #endif
    /// 定义一个私有方法 stopService，用于停止 VPN 服务。
    private func stopService() {
        if let service = boxService {
            do {
                // 调用 service.close() 关闭服务。
                try service.close()
            } catch {
                writeMessage("(packet-tunnel) error: stop service: \(error.localizedDescription)")
            }
            // 将 boxService 设置为 nil，释放服务实例
            boxService = nil
            commandServer.setService(nil)
        }
        // 如果 platformInterface 不为 nil，则调用其 reset 方法重置平台接口。
        if let platformInterface {
            platformInterface.reset()
        }
    }
    /// 定义一个异步方法 reloadService，用于重新加载 VPN 服务。
    func reloadService() async {
        writeMessage("(packet-tunnel) reloading service")
        // 设置 reasserting 属性为 true，告知系统隧道正在重新声明。
        reasserting = true
        defer { // 使用 defer 块确保在方法退出时将 reasserting 设置回 false。
            reasserting = false
        }
        // 停止当前服务。
        stopService()
        // 重置命令服务器的日志。
        commandServer.resetLog()
        // 异步启动新的服务
        await startService()
    }
    /// 定义一个方法 postServiceClose，在服务关闭后清除服务引用
    func postServiceClose() {
        boxService = nil
    }

    /// 重写父类的 stopTunnel 方法，用于停止 VPN 隧道。
    override open func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        // 调用 stopService 方法停止 VPN 服务。
        stopService()
        // 尝试暂停执行 100 毫秒，给服务一些时间完成清理工作。
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            // 尝试关闭命令服务器
            try? server.close()
            // 将 commandServer 设置为 nil，释放资源。
            commandServer = nil
        }
        #if os(macOS)
            if reason == .userInitiated {
                await SharedPreferences.startedByUser.set(reason == .userInitiated)
            }
        #endif
        #if os(iOS)
        // 重新加载控制中心中的特定控件
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }
    /// 重写父类的 handleAppMessage 方法，用于处理来自应用的消息。
    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        messageData
    }
    /// 重写父类的 sleep 方法，当设备进入睡眠状态时调用。
    override open func sleep() async {
        if let boxService {
            boxService.pause()
        }
    }
    /// 重写父类的 wake 方法，当设备从睡眠状态唤醒时调用。
    override open func wake() {
        if let boxService {
            boxService.wake()
        }
    }
}
