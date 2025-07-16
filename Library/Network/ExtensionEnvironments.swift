import Foundation
import SwiftUI

/// 定义一个公开的类 ExtensionEnvironments，继承自 ObservableObject。
/// ObservableObject 是 SwiftUI 中的协议，允许 SwiftUI 视图观察并响应对象状态的变化
/*
 这个类管理 VPN 扩展的环境状态，包括配置文件的加载、状态追踪和日志连接。它充当 VPN 扩展与应用程序界面之间的桥梁，为 SwiftUI 视图提供可观察的状态。
 */
public class ExtensionEnvironments: ObservableObject {
    /// @Published 是属性包装器，当属性值变化时会通知观察者。
    
    /// ogClient: 日志客户端实例，初始化为 .log 类型的 CommandClient。
    @Published public var logClient = CommandClient(.log)
    /// extensionProfileLoading: 布尔值，指示扩展配置文件是否正在加载，初始值为 true。
    @Published public var extensionProfileLoading = true
    /// extensionProfile: 可选的 ExtensionProfile 实例，表示当前的扩展配置文件。
    @Published public var extensionProfile: ExtensionProfile?
    /// emptyProfiles: 布尔值，指示是否没有配置文件，初始值为 false。
    @Published public var emptyProfiles = false
    
    /// 三个自定义的发布器，用于通知对象状态即将变化：
    
    /// 当配置文件更新时通知。
    public let profileUpdate = ObjectWillChangePublisher()
    
    /// 当选定的配置文件改变时通知。
    public let selectedProfileUpdate = ObjectWillChangePublisher()
    
    /// 当需要打开设置时通知。
    public let openSettings = ObjectWillChangePublisher()
    
    /// 空的初始化方法。
    public init() {}
    
    /// 构方法，在对象被销毁前断开日志客户端的连接，防止资源泄露
    deinit {
        logClient.disconnect()
    }
    
    /// 公开方法，创建一个异步任务来调用 reload()。
    public func postReload() {
        // 使用 Task 创建异步上下文，因为它需要调用异步方法 reload()。
        Task {
            await reload()
        }
    }
    
    /// 重新加载方法（异步版本）
    /// @MainActor: 表示此方法在主线程上执行，适用于需要更新 UI 的代码。
    @MainActor public func reload() async {
        // 尝试异步加载扩展配置文件，如果成功则执行后续代码。
        if let newProfile = try? await ExtensionProfile.load() {
            // 如果当前没有配置文件或配置文件状态无效，则：
            // 更新 extensionProfile 属性为新加载的配置文件。
            // 将 extensionProfileLoading 设置为 false，表示加载已完成。注册新配置文件（可能设置监听器或初始化资源）。
            if extensionProfile == nil || extensionProfile?.status == .invalid {
                // 用于注册 VPN 状态变化的观察者。
                newProfile.register()
                extensionProfile = newProfile
                extensionProfileLoading = false
            }
            // 如果当前配置文件已加载且状态有效，则：
        } else {
            extensionProfile = nil
            extensionProfileLoading = false
        }
    }
    
    /// 定义一个公开方法 connectLog()，用于连接到日志服务。
    public func connectLog() {
        guard let profile = extensionProfile else {
            return
        }
        // 如果配置文件状态为已连接，且日志客户端未连接，则连接日志客户端。
        if profile.status.isConnected, !logClient.isConnected {
            logClient.connect()
        }
    }
}
