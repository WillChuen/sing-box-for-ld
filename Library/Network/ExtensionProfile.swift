import Foundation
import Libbox
import NetworkExtension

/// 定义一个名为 ExtensionProfile 的公开类，遵循 ObservableObject 协议。
/// ObservableObject 是 SwiftUI 的一个协议，允许视图观察和响应对象属性的变化。
public class ExtensionProfile: ObservableObject {
    
    /// 定义一个公开的静态常量 controlKind，值为一个字符串标识符
    /// 这个标识符用于标识小组件控件，尤其是在控制中心或桌面小组件中用于 VPN 服务的开关控件
    public static let controlKind = "ld.nekohasekai.sfavt.widget.ServiceToggle"

    /// 私有常量，类型为 NEVPNManager，用于管理 VPN 配置
    private let manager: NEVPNManager
    
    /// 私有变量，类型为 NEVPNConnection，表示当前的 VPN 连接。
    private var connection: NEVPNConnection
    
    /// 私有变量 observer，用于存储通知观察者的引用，以便在不需要时可以取消注册。
    private var observer: Any?
    
    /// 声明一个公开的 status 属性，类型为 NEVPNStatus，表示 VPN 连接状态。
    /// 这个属性使用 @Published 属性包装器，这样当状态变化时，SwiftUI 可以自动更新相关的视图。
    @Published public var status: NEVPNStatus

    /// 初始化方法，接受一个 NEVPNManager 实例作为参数。
    public init(_ manager: NEVPNManager) {
        self.manager = manager
        connection = manager.connection
        status = manager.connection.status
    }

    /// 定义一个公开方法 register，用于注册 VPN 状态变化的观察者。
    public func register() {
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] notification in
            guard let self else {
                return
            }
            self.connection = notification.object as! NEVPNConnection
            self.status = self.connection.status
        }
    }
    
    /// 定义一个私有方法 unregister，用于移除之前注册的观察者。
    private func unregister() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 设置按需规则方法
    private func setOnDemandRules() {
        // 创建一个接口规则 interfaceRule，匹配任何类型的网络接口。
        let interfaceRule = NEOnDemandRuleConnect()
        interfaceRule.interfaceTypeMatch = .any
        // 创建一个探测规则 probeRule，使用 Apple 的验证门户网址进行网络可达性测试。
        let probeRule = NEOnDemandRuleConnect()
        probeRule.probeURL = URL(string: "http://captive.apple.com")
        // 将这两个规则设置为 VPN 管理器的按需规则
        manager.onDemandRules = [interfaceRule, probeRule]
    }

    /// 定义一个公开的异步方法 updateAlwaysOn，用于更新 VPN 的始终开启状态
    public func updateAlwaysOn(_ newState: Bool) async throws {
        // 设置 manager.isOnDemandEnabled 属性为传入的新状态值。
        manager.isOnDemandEnabled = newState
        // 用 setOnDemandRules 方法设置按需规则。
        setOnDemandRules()
        // 异步保存配置到系统偏好设置，可能会抛出错误。
        try await manager.saveToPreferences()
    }
    
    /// 获取最后断开错误方法
    @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
    public func fetchLastDisconnectError() async throws {
        try await connection.fetchLastDisconnectError()
    }

    /// 定义一个公开的异步方法 start，用于启动 VPN 连接。
    public func start() async throws {
        // 异步调用 fetchProfile() 获取配置文件。
        await fetchProfile()
        // 设置 manager.isEnabled 为 true，启用 VPN 配置。
        manager.isEnabled = true
        // 异步检查用户是否启用了"始终开启"选项。
        if await SharedPreferences.alwaysOn.get() {
            manager.isOnDemandEnabled = true
            setOnDemandRules()
        }
        #if !os(tvOS)
        // 异步获取用户是否选择包含所有网络的设置。
            if let protocolConfiguration = manager.protocolConfiguration {
                let includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
                protocolConfiguration.includeAllNetworks = includeAllNetworks
                if #available(iOS 16.4, macOS 13.3, *) {
                    protocolConfiguration.excludeCellularServices = !includeAllNetworks
                }
            }
        #endif
        // 异步保存 VPN 配置到系统偏好设置，可能会抛出错误。
        try await manager.saveToPreferences()
        #if os(macOS)
            if Variant.useSystemExtension {
                try manager.connection.startVPNTunnel(options: [
                    "username": NSString(string: NSUserName()),
                ])
                return
            }
        #endif
        // 调用 startVPNTunnel 方法启动 VPN 连接，不传入任何选项，可能会抛出错误。
        try manager.connection.startVPNTunnel()
    }

    /// 获取配置文件方法
    public func fetchProfile() async {
        do {
            if let profile = try await ProfileManager.get(Int64(SharedPreferences.selectedProfileID.get())) {
                if profile.type == .icloud {
                    _ = try profile.read()
                }
            }
        } catch {}
    }
    
    /// 定义一个公开的异步方法 stop，用于停止 VPN 连接。
    public func stop() async throws {
        // 检查是否启用了按需连接。
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        do {
            // 尝试创建一个独立命令客户端并调用 serviceClose 方法关闭服务。
            try LibboxNewStandaloneCommandClient()!.serviceClose()
        } catch {}
        // 调用 stopVPNTunnel 方法停止 VPN 隧道。
        manager.connection.stopVPNTunnel()
    }
    /// 定义一个公开的静态异步方法 load，用于加载 VPN 配置。
    public static func load() async throws -> ExtensionProfile? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if managers.isEmpty {
            return nil
        }
        let profile = ExtensionProfile(managers[0])
        return profile
    }
    
    /// 定义一个公开的静态异步方法 install，用于安装 VPN 配置。
    public static func install() async throws {
        // 创建一个新的 NETunnelProviderManager 实例。
        let manager = NETunnelProviderManager()
        // 设置本地化描述为应用名称。
        manager.localizedDescription = Variant.applicationName
        // 创建一个新的 NETunnelProviderProtocol 实例，用于配置 VPN 隧道协议。
        let tunnelProtocol = NETunnelProviderProtocol()
        // 根据是否使用系统扩展设置提供者的包标识符。
        if Variant.useSystemExtension {
            tunnelProtocol.providerBundleIdentifier = "\(FilePath.packageName).system"
        } else {
            tunnelProtocol.providerBundleIdentifier = "\(FilePath.packageName).extension"
        }
        // 设置服务器地址为 "sing-box"（这里是一个标识符，非实际服务器地址）。
        tunnelProtocol.serverAddress = "sing-box"
        // 将创建的协议配置设置到管理器中。
        manager.protocolConfiguration = tunnelProtocol
        // 启用 VPN 管理器。
        manager.isEnabled = true
        // 异步保存配置到系统偏好设置，可能会抛出错误。
        do {
            try await manager.saveToPreferences()
        } catch {
            throw error
        }
    }
}
