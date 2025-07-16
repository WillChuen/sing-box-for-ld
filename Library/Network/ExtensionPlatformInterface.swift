import Foundation
import Libbox
import NetworkExtension
import UserNotifications
#if os(macOS)
    import CoreWLAN
#endif

/// 定义名为 ExtensionPlatformInterface 的公开类，继承自 NSObject。
/// 此类实现了 LibboxPlatformInterfaceProtocol 和 LibboxCommandServerHandlerProtocol 协议。
public class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    
    /// 返回一个 LibboxLocalDNSTransportProtocol 的实例。
    public func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        return nil
    }
    
    /// 返回一个 LibboxLocalDNSResolverProtocol 的实例。
    public func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        return nil
    }
    
    /// tunnel: 私有常量，引用 ExtensionProvider 实例，用于控制 VPN 隧道。
    private let tunnel: ExtensionProvider
    
    /// networkSettings: 可选的 NEPacketTunnelNetworkSettings 实例，用于配置网络设置。
    private var networkSettings: NEPacketTunnelNetworkSettings?
    
    /// 初始化方法，接受一个 ExtensionProvider 实例作为参数。
    init(_ tunnel: ExtensionProvider) {
        self.tunnel = tunnel
    }
    
    /// 实现协议方法，打开 TUN 设备（虚拟网络接口）。
    public func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        // 使用 runBlocking 函数，将异步操作转换为同步操作。
        try runBlocking { [self] in
            // 调用 openTun0 方法执行具体逻辑。
            try await openTun0(options, ret0_)
        }
    }
    
    /// 私有异步方法，实现打开 TUN 设备的具体逻辑。
    /// 接受 TUN 选项和返回文件描述符的指针。
    private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        // 确保 options  不为 nil，否则抛出错误。
        guard let options else {
            throw NSError(domain: "nil options", code: 0)
        }
        // 检查 ret0_ 是否为 nil，如果是，则抛出错误。
        guard let ret0_ else {
            throw NSError(domain: "nil return pointer", code: 0)
        }
        // 是否默认使用子范围路由。
        let autoRouteUseSubRangesByDefault = await SharedPreferences.autoRouteUseSubRangesByDefault.get()
        // 是否排除 Apple 推送通知服务 (APNs) 路由。
        let excludeAPNs = await SharedPreferences.excludeAPNsRoute.get()
        // 创建网络设置对象，设置隧道远程地址为本地回环地址。
        // 作用：tunnelRemoteAddress 是 VPN 隧道的"远程端点"，代表 VPN 服务器地址。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // 检查是否启用自动路由设置。
        if options.getAutoRoute() {
            // 设置最大传输单元 (MTU) 值。
            settings.mtu = NSNumber(value: options.getMTU())
            // 获取 DNS 服务器地址，创建 DNS 设置。
            let dnsServer = try options.getDNSServerAddress()
            let dnsSettings = NEDNSSettings(servers: [dnsServer.value])
            // 置匹配所有域名 ([""])
            dnsSettings.matchDomains = [""]
            // 禁用域名搜索功能
            dnsSettings.matchDomainsNoSearch = true
            // 将 DNS 设置应用到网络设置中
            settings.dnsSettings = dnsSettings
            
            // 获取 IPv4 地址和子网掩码列表。
            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            // 使用迭代器遍历所有 IPv4 地址，添加到列表中
            while ipv4AddressIterator.hasNext() {
                let ipv4Prefix = ipv4AddressIterator.next()!
                ipv4Address.append(ipv4Prefix.address())
                ipv4Mask.append(ipv4Prefix.mask())
            }

            // 创建 IPv4 设置对象，传入地址和掩码列表。
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
            // 初始化路由和排除路由列表
            var ipv4Routes: [NEIPv4Route] = []
            var ipv4ExcludeRoutes: [NEIPv4Route] = []
            
            // 获取 IPv4 路由地址列表。
            let inet4RouteAddressIterator = options.getInet4RouteAddress()!
            // 如果有指定的路由，添加到路由列表中。
            if inet4RouteAddressIterator.hasNext() {
                
                while inet4RouteAddressIterator.hasNext() {
                    let ipv4RoutePrefix = inet4RouteAddressIterator.next()!
                    ipv4Routes.append(NEIPv4Route(destinationAddress: ipv4RoutePrefix.address(), subnetMask: ipv4RoutePrefix.mask()))
                }
                // 如果没有指定路由且启用默认子范围，执行下面的代码。
                // 这是在NetworkExtension框架中的一种变通方法，主要用于解决以下问题：
                // 避免直接使用默认路由：在某些iOS版本或场景中，直接设置0.0.0.0/0的默认路由可能会导致问题。
                // 更精细的路由控制：拆分路由允许更细粒度的控制，可以通过添加额外的排除路由来绕过特定网段。
                // iOS对NetworkExtension框架有一些限制，这种方法可以绕过某些限制。
                // 排除0.0.0.0/8：注意这种方式实际上不包括0.0.0.0/8网段，这是有意为之，因为该网段通常不用于实际通信。这种方法在不同的iOS/macOS版本上有更好的兼容性。
                // 这种技术在VPN和网络扩展开发中被称为"子网段路由拆分"(subnet route splitting)，是处理全局路由的一种常见方法。
            } else if autoRouteUseSubRangesByDefault {
                ipv4Routes.append(NEIPv4Route(destinationAddress: "1.0.0.0", subnetMask: "255.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "2.0.0.0", subnetMask: "254.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "4.0.0.0", subnetMask: "252.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "8.0.0.0", subnetMask: "248.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "16.0.0.0", subnetMask: "240.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "32.0.0.0", subnetMask: "224.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "64.0.0.0", subnetMask: "192.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"))
                // 如果没有指定路由且不使用子范围，添加默认路由（0.0.0.0/0）。
            } else {
                ipv4Routes.append(NEIPv4Route.default())
            }
            
            // 获取要排除的 IPv4 路由列表，添加到排除路由列表中。
            let inet4RouteExcludeAddressIterator = options.getInet4RouteExcludeAddress()!
            while inet4RouteExcludeAddressIterator.hasNext() {
                let ipv4RoutePrefix = inet4RouteExcludeAddressIterator.next()!
                ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: ipv4RoutePrefix.address(), subnetMask: ipv4RoutePrefix.mask()))
            }
            // 如果用户设置了排除默认路由且有路由配置，添加 0.0.0.0/31 到排除列表。
            // 这是一个技巧，用于排除某些流量不走 VPN。
            // NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254") 这个路由配置指定了一个非常特殊的 IPv4 路由：
            // 技术解析:
            // 这是一个 IPv4 CIDR 为 0.0.0.0/31 的路由规则，它具有以下特点：
            // 目标地址: 0.0.0.0 - 这是 IPv4 地址空间的最开始部分
            // 子网掩码: 255.255.255.254 - 这对应于 /31 前缀长度，只包含两个 IP 地址：0.0.0.0 和 0.0.0.1
            /*
             实际含义:
             这是一个 技巧性用法，用于在 NetworkExtension 框架中实现以下功能：
             目的: 排除默认路由，但不完全禁用路由
             原理: 通过排除这个特殊的小范围路由（仅包含 2 个 IP 地址）
             效果: 允许某些特定流量（如系统服务）绕过 VPN，直接使用物理网络接口
             为什么不直接排除 0.0.0.0/0？
             在 NetworkExtension 框架中，如果直接尝试排除 0.0.0.0/0（完整的默认路由），可能会导致路由冲突或 VPN 完全无效。这个 /31 子网是一个巧妙的妥协方案，只排除了两个特定的 IP 地址，而不影响整体 VPN 功能。
             这种技术在开发网络扩展时经常使用，尤其是当需要微调路由行为，允许某些流量绕过 VPN 隧道时。
             */
            if await SharedPreferences.excludeDefaultRoute.get(), !ipv4Routes.isEmpty {
                if !ipv4ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "0.0.0.0" && it.destinationSubnetMask == "255.255.255.254"
                }) {
                    ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"))
                }
            }
            /*
             如果排除 APNs 且有路由配置，添加 17.0.0.0/8（Apple 的 IP 范围）到排除列表。
             这确保 Apple 推送通知服务不走 VPN，避免通知延迟。
             这个路由配置指向了 Apple 公司拥有的 IP 地址范围。具体来说：
             目标地址：17.0.0.0 - 这是 Apple 公司拥有的 IP 地址块的起始地址
             子网掩码：255.0.0.0 - 表示 /8 前缀，覆盖了从 17.0.0.0 到 17.255.255.255 的所有 IP 地址
             实际功能
             排除 Apple 推送通知服务 (APNs)：当 excludeAPNs 为 true 时，将 Apple 的 IP 范围添加到排除路由列表中
             确保推送通知正常工作：通过让 Apple 的服务器流量绕过 VPN 隧道，直接使用设备的物理网络接口
             减少通知延迟：如果 APNs 流量通过 VPN，可能会导致推送通知延迟或丢失
             为什么这很重要
             用户体验：确保用户即使在使用 VPN 时也能及时收到推送通知
             电池寿命：APNs 使用特殊的低功耗长连接，让它走物理网络可以帮助节省电量
             稳定性：某些 VPN 实现可能会干扰 APNs 的连接保持机制
             */
            if excludeAPNs, !ipv4Routes.isEmpty {
                if !ipv4ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "17.0.0.0" && it.destinationSubnetMask == "255.0.0.0"
                }) {
                    ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: "17.0.0.0", subnetMask: "255.0.0.0"))
                }
            }
            // 设置 IPv4 包含和排除路由，并应用到网络设置中。
            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
            settings.ipv4Settings = ipv4Settings

            // IPv6 设置
            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            // 获取 IPv6 地址和前缀长度列表。
            let ipv6AddressIterator = options.getInet6Address()!
            // 类似于 IPv4 的处理，遍历所有 IPv6 地址并添加到列表中。
            while ipv6AddressIterator.hasNext() {
                let ipv6Prefix = ipv6AddressIterator.next()!
                ipv6Address.append(ipv6Prefix.address())
                ipv6Prefixes.append(NSNumber(value: ipv6Prefix.prefix()))
            }
            // 创建 IPv6 设置对象，传入地址和前缀长度列表。
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
            // 初始化 IPv6 路由和排除路由列表。
            var ipv6Routes: [NEIPv6Route] = []
            var ipv6ExcludeRoutes: [NEIPv6Route] = []

            // 获取 IPv6 路由地址列表。
            let inet6RouteAddressIterator = options.getInet6RouteAddress()!
            // 如果有指定的路由，添加到路由列表中。
            if inet6RouteAddressIterator.hasNext() {
                while inet6RouteAddressIterator.hasNext() {
                    let ipv6RoutePrefix = inet6RouteAddressIterator.next()!
                    ipv6Routes.append(NEIPv6Route(destinationAddress: ipv6RoutePrefix.address(), networkPrefixLength: NSNumber(value: ipv6RoutePrefix.prefix())))
                }
            }// 如果没有指定路由且启用默认子范围，执行下面的代码。
            // 添加一系列 IPv6 子范围路由，覆盖整个 IPv6 地址空间。
            // 类似于 IPv4 的处理，避免使用单一的默认路由。
            else if autoRouteUseSubRangesByDefault {
                ipv6Routes.append(NEIPv6Route(destinationAddress: "100::", networkPrefixLength: 8))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "200::", networkPrefixLength: 7))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "400::", networkPrefixLength: 6))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "800::", networkPrefixLength: 5))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "1000::", networkPrefixLength: 4))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "2000::", networkPrefixLength: 3))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "4000::", networkPrefixLength: 2))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1))
            }// 如果没有指定路由且不使用子范围，添加默认 IPv6 路由（::/0）。
            else {
                ipv6Routes.append(NEIPv6Route.default())
            }
            // 获取要排除的 IPv6 路由列表，添加到排除路由列表中。
            let inet6RouteExcludeAddressIterator = options.getInet6RouteExcludeAddress()!
            while inet6RouteExcludeAddressIterator.hasNext() {
                let ipv6RoutePrefix = inet6RouteExcludeAddressIterator.next()!
                ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: ipv6RoutePrefix.address(), networkPrefixLength: NSNumber(value: ipv6RoutePrefix.prefix())))
            }
            // 为什么在这里不需要跟IPV4那样排除默认路由和排除APNS相关路由
            /*
             IPv6 不需要排除默认路由的原因
             不同的网络栈处理方式:
             Pv4 和 IPv6 在系统网络栈中被独立处理
             排除 IPv4 默认路由的技巧（0.0.0.0/31）是针对 IPv4 特定实现的
             IPv6 路由控制更加现代化:
             IPv6 在 NetworkExtension 框架中的路由处理通常更加可靠
             不需要使用像 IPv4 那样的变通方法来排除特定流量
             历史兼容性问题:
             许多 IPv4 的变通方法是为了解决旧版 iOS 的兼容性问题
             IPv6 作为较新的协议，实现时已经避免了这些问题
             IPv6 不需要排除 APNs 的原因
             Apple 推送服务的 IP 地址分配:
             APNs 服务器主要使用 IPv4 地址空间中的 17.0.0.0/8
             Apple 没有专门为 APNs 分配明确的 IPv6 地址块
             即使 APNs 未来使用 IPv6，也可能使用多个不同的地址块
             双栈环境中的回退机制:
             在大多数 iOS/macOS 设备上，APNs 即使有 IPv6 地址可用，也会优先使用 IPv4
             排除 IPv4 的 17.0.0.0/8 已经足以保证 APNs 通信不受 VPN 影响
             */
            // 设置 IPv6 包含和排除路由，并应用到网络设置中。
            ipv6Settings.includedRoutes = ipv6Routes
            ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
            settings.ipv6Settings = ipv6Settings
        }
        
        // 检查是否启用 HTTP 代理。
        if options.isHTTPProxyEnabled() {
            // 创建代理设置对象。
            let proxySettings = NEProxySettings()
            // 创建代理服务器对象，使用指定的地址和端口。
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            // 将同一代理服务器设置为 HTTP 和 HTTPS 代理。
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            // 如果用户启用了系统代理，启用 HTTP 和 HTTPS 代理。
            if await SharedPreferences.systemProxyEnabled.get() {
                proxySettings.httpEnabled = true
                proxySettings.httpsEnabled = true
            }
            // 获取代理绕过域名列表。
            var bypassDomains: [String] = []
            let bypassDomainIterator = options.getHTTPProxyBypassDomain()!
            // 遍历所有绕过域名，添加到列表中。
            while bypassDomainIterator.hasNext() {
                bypassDomains.append(bypassDomainIterator.next())
            }
            // 如果排除 APNs，确保 "push.apple.com" 在绕过列表中。
            if excludeAPNs {
                if !bypassDomains.contains(where: { it in
                    it == "push.apple.com"
                }) {
                    bypassDomains.append("push.apple.com")
                }
            }
            // 如果有绕过域名，设置为代理例外列表。
            if !bypassDomains.isEmpty {
                proxySettings.exceptionList = bypassDomains
            }
            // 获取代理匹配域名列表。
            var matchDomains: [String] = []
            let matchDomainIterator = options.getHTTPProxyMatchDomain()!
            while matchDomainIterator.hasNext() {
                matchDomains.append(matchDomainIterator.next())
            }
            // 如果有匹配域名，设置为代理匹配列表。
            // 匹配列表指定只有这些域名才使用代理。
            if !matchDomains.isEmpty {
                proxySettings.matchDomains = matchDomains
            }
            // 将代理设置应用到网络设置中。
            settings.proxySettings = proxySettings
        }
        // 保存网络设置到实例属性中，以便后续使用。
        networkSettings = settings
        // 异步设置隧道的网络设置。
        try await tunnel.setTunnelNetworkSettings(settings)

        // 尝试通过 KVC（键-值编码）获取 TUN 设备的文件描述符。
        // 如果成功，设置返回值并返回。
        // 这是一种非公开的方法，可能在某些 iOS 版本上不可用。
        //  获取 NetworkExtension 框架中 NEPacketTunnelFlow 对象所使用的底层网络套接字的文件描述符
        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        // 调用 LibboxGetTunnelFileDescriptor() 获取文件描述符。
        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        // 如果成功（返回值不为 -1），设置返回值。
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw NSError(domain: "missing file descriptor", code: 0)
        }
    }
    /// 实现协议方法，指定是否使用平台自动检测控制。
    public func usePlatformAutoDetectControl() -> Bool {
        false
    }

    /// 实现协议方法，用于自动检测控制。
    /// 空实现，因为不使用此功能。
    public func autoDetectControl(_: Int32) throws {}

    /// 实现协议方法，用于查找连接所有者。
    /// 抛出"未实现"错误，表示不支持此功能。
    public func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32, ret0_ _: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "not implemented", code: 0)
    }

    /// 实现协议方法，根据 UID 获取包名。
    /// 返回空字符串，表示不支持此功能。
    public func packageName(byUid _: Int32, error _: NSErrorPointer) -> String {
        ""
    }

    /// 实现协议方法，根据包名获取 UID。
    /// 抛出"未实现"错误，表示不支持此功能。
    public func uid(byPackageName _: String?, ret0_ _: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "not implemented", code: 0)
    }

    /// 实现协议方法，指定是否使用 procfs（进程文件系统）。
    /// 返回 false，因为 iOS/macOS 不使用 procfs。
    public func useProcFS() -> Bool {
        false
    }

    /// 实现协议方法，用于写入日志。
    /// 如果消息为 nil，直接返回。
    /// 调用隧道的 writeMessage 方法记录日志。
    public func writeLog(_ message: String?) {
        guard let message else {
            return
        }
        tunnel.writeMessage(message)
    }

    /// 声明私有可选变量，用于存储网络路径监控器。
    private var nwMonitor: NWPathMonitor? = nil

    public func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else {
            return
        }
        // 创建网络路径监控器。
        let monitor = NWPathMonitor()
        // 保存到实例属性中。
        nwMonitor = monitor
        // 创建一个信号量，用于同步。
        let semaphore = DispatchSemaphore(value: 0)
        // 设置路径更新处理器。
        monitor.pathUpdateHandler = { path in
            // 首次调用时，更新默认接口并增加信号量。
            self.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
            // 然后替换为新的处理器，后续只更新默认接口，不增加信号量。
            monitor.pathUpdateHandler = { path in
                self.onUpdateDefaultInterface(listener, path)
            }
        }
        // 在全局队列上启动监控器。
        monitor.start(queue: DispatchQueue.global())
        // 等待信号量，确保首次更新已完成。
        semaphore.wait()
    }

    /// 私有方法，处理默认接口更新。
    private func onUpdateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        // 如果网络状态不满足，通知监听器无可用接口。
        if path.status == .unsatisfied {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
        } else {
            // 否则使用第一个可用接口作为默认接口，并提供接口名称、索引和特性。
            let defaultInterface = path.availableInterfaces.first!
            listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
    }

    /// 实现协议方法，关闭默认接口监控。
    /// 取消监控器并清除引用。
    public func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }
    
    /// 实现协议方法，获取网络接口列表。
    public func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw NSError(domain: "NWMonitor not started", code: 0)
        }
        // 获取当前网络路径。
        let path = nwMonitor.currentPath
        // 如果网络状态不满足，返回空接口列表。
        if path.status == .unsatisfied {
            return networkInterfaceArray([])
        }
        // 遍历所有可用接口，创建 LibboxNetworkInterface 对象。
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            // 设置接口名称和索引。
            interface.name = it.name
            interface.index = Int32(it.index)
            // 根据接口类型设置对应的类型常量。
            switch it.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return networkInterfaceArray(interfaces)
    }
    
    /// 网络接口数组类
    class networkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        /// 使用 Swift 的 IndexingIterator 封装接口数组。
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }
        ///
        private var nextValue: LibboxNetworkInterface? = nil
        /// hasNext 方法获取下一个值并检查是否存在。
        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }
        /// ext 方法返回上次获取的值。
        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }
    
    /// 返回 true，因为这个类是为网络扩展设计的。
    public func underNetworkExtension() -> Bool {
        true
    }
    
    /// 实现协议方法，检查是否包含所有网络。
    public func includeAllNetworks() -> Bool {
        #if !os(tvOS)
            return SharedPreferences.includeAllNetworks.getBlocking()
        #else
            return false
        #endif
    }
    
    /// 实现协议方法，清除 DNS 缓存
    public func clearDNSCache() {
        guard let networkSettings else {
            return
        }
        // 设置 reasserting 为 true，表示正在重新声明隧道。
        tunnel.reasserting = true
        // 先清除网络设置，然后重新应用网络设置，以清除 DNS 缓存。
        tunnel.setTunnelNetworkSettings(nil) { _ in
        }
        tunnel.setTunnelNetworkSettings(networkSettings) { _ in
        }
        // 完成后设置 reasserting 为 false。
        tunnel.reasserting = false
    }
    
    /// 实现协议方法，读取 WiFi 状态。
    public func readWIFIState() -> LibboxWIFIState? {
        #if os(iOS)
            let network = runBlocking {
                await NEHotspotNetwork.fetchCurrent()
            }
            guard let network else {
                return nil
            }
            return LibboxWIFIState(network.ssid, wifiBSSID: network.bssid)!
        #elseif os(macOS)
            guard let interface = CWWiFiClient.shared().interface() else {
                return nil
            }
            guard let ssid = interface.ssid() else {
                return nil
            }
            guard let bssid = interface.bssid() else {
                return nil
            }
            return LibboxWIFIState(ssid, wifiBSSID: bssid)!
        #else
            return nil
        #endif
    }

    /// 实现协议方法，重新加载服务。
    public func serviceReload() throws {
        runBlocking { [self] in
            await tunnel.reloadService()
        }
    }

    /// 实现协议方法，处理服务关闭后的操作。
    public func postServiceClose() {
        // 调用 reset 方法重置状态
        reset()
        // 调用隧道的 postServiceClose 方法
        tunnel.postServiceClose()
    }
    
    /// 实现协议方法，获取系统代理状态。
    public func getSystemProxyStatus() -> LibboxSystemProxyStatus? {
        let status = LibboxSystemProxyStatus()
        guard let networkSettings else {
            return status
        }
        guard let proxySettings = networkSettings.proxySettings else {
            return status
        }
        if proxySettings.httpServer == nil {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    /// 实现协议方法，设置系统代理启用状态。
    /// 检查网络设置、代理设置和 HTTP 代理服务器是否存在。
    public func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings else {
            return
        }
        guard let proxySettings = networkSettings.proxySettings else {
            return
        }
        if proxySettings.httpServer == nil {
            return
        }
        // 如果当前状态与目标状态相同，直接返回。
        if proxySettings.httpEnabled == isEnabled {
            return
        }
        // 设置 HTTP 和 HTTPS 代理的启用状态。
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        // 更新网络设置中的代理设置。
        networkSettings.proxySettings = proxySettings
        // 使用 runBlocking 将异步操作转为同步操作。
        try runBlocking {
            // 应用更新后的网络设置到隧道。
            try await self.tunnel.setTunnelNetworkSettings(networkSettings)
        }
    }

    /// 定义方法，重置接口状态。
    func reset() {
        networkSettings = nil
    }
    
    /// 实现协议方法，发送系统通知。
    public func send(_ notification: LibboxNotification?) throws {
        #if !os(tvOS)
            guard let notification else {
                return
            }
        // 获取通知中心，创建通知内容。
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
        // 设置标题、副标题和正文。
            content.title = notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
        // 如果有打开 URL，添加到用户信息中。
            if !notification.openURL.isEmpty {
                content.userInfo["OPEN_URL"] = notification.openURL
                // 设置类别标识符，以便系统可以处理打开 URL 的操作。
                content.categoryIdentifier = "OPEN_URL"
            }
        // 设置中断级别为活跃，表示可以立即显示通知。
            content.interruptionLevel = .active
        // 创建通知请求，使用通知 ID、内容，不使用触发器（立即显示）。
            let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        // 使用 runBlocking 将异步操作转为同步操作。
            try runBlocking {
                // 请求通知授权，然后添加通知请求。
                try await center.requestAuthorization(options: [.alert])
                try await center.add(request)
            }
        #endif
    }
}
