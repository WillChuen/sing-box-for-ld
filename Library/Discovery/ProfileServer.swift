import Foundation
import Libbox
import Network

/// 定义一个公开的类 ProfileServer，外部代码可以访问此类。
public class ProfileServer {
    /// 声明一个私有变量 listener，类型为 NWListener（Network 框架中的网络监听器），用于监听网络连接请求。
    private var listener: NWListener
    
    /// 表示此初始化方法仅在 iOS 16.0 和 macOS 13.0 及更高版本可用。
    @available(iOS 16.0, macOS 13.0, *)
    public init() throws {
        
        // 创建一个 NWListener 实例，使用 .applicationService 参数表示这是一个应用服务类型的监听器。
        listener = try NWListener(using: .applicationService)
        
        // 设置监听器的服务标识为 "sing-box:profile"，这是一个自定义的服务标识符，用于 Bonjour/mDNS 服务发现。
        listener.service = NWListener.Service(applicationService: "sing-box:profile")
        
        // 设置监听器收到新连接时的处理闭包。参数 connection 是一个 NWConnection 类型，表示新建立的连接。
        listener.newConnectionHandler = { connection in
            
            // 为连接设置状态更新处理器，当连接状态发生变化时会调用此闭包。参数 state 表示连接的新状态。
            connection.stateUpdateHandler = { state in
                
                // 检查连接状态是否为 .ready（已准备好），表示连接已成功建立并可以收发数据
                if state == .ready {
                    // 创建一个分离的异步任务，在后台线程执行以下代码块。
                    Task.detached {
                        // 使任务暂停 100 毫秒，NSEC_PER_MSEC 是每毫秒的纳秒数，这行给连接一些时间稳定下来。
                        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 100)
                        
                        // 创建一个 ProfileConnection 实例并调用其 process() 方法处理连接。await 表示这是一个异步操作。
                        await ProfileConnection(connection).process()
                    }
                }
            }
            // 在全局队列中启动连接，使其开始接收和发送数据。
            connection.start(queue: .global())
        }
    }
    /// 方法启动监听器，在全局队列中运行，开始监听客户端连接请求。
    public func start() {
        listener.start(queue: .global())
    }
    /// 方法取消监听器，停止监听客户端连接请求。
    public func cancel() {
        listener.cancel()
    }

    /// 定义内部类 ProfileConnection，用于处理单个客户端连接。
    class ProfileConnection {
        
        /// 声明私有常量 connection，类型为 NWSocket（可能是对 NWConnection 的封装）。
        private let connection: NWSocket
        
        /// 初始化方法，接受一个 NWConnection 参数，并将其封装为 NWSocket。
        init(_ connection: NWConnection) {
            self.connection = NWSocket(connection)
        }
        
        /// process() 方法定义为 async，表示这是一个异步方法。
        func process() async {
            do {
                // 使用 try await 调用 writeProfilePreviewList() 方法，发送配置文件预览列表给客户端。
                try await writeProfilePreviewList()
            } catch {
                // 如果发送预览列表时出现错误，记录错误日志并向客户端发送错误信息，然后返回。
                NSLog("profile server: write profile list: \(error.localizedDescription)")
                writeError(error.localizedDescription)
                return
            }
            do {
                // 进入无限循环，不断尝试从连接读取消息，并处理每条消息。
                while true {
                    let message = try connection.read()
                    try processMessage(message)
                }
            } catch {
                // 如果在读取或处理消息时出现错误，记录错误日志并向客户端发送错误信息。
                NSLog("profile server: process connection: \(error.localizedDescription)")
                writeError(error.localizedDescription)
            }
        }
        /// 方法接受一个 Data 类型的参数，表示接收到的消息数据。
        private func processMessage(_ data: Data) throws {
            // 如果数据为空（长度为 0），则直接返回，不做处理。
            if data.count == 0 {
                return
            }
            // 从数据的第一个字节解析出消息类型，转换为 Int64 类型。
            let messageType = Int64(data[0])
            // 使用 switch 语句根据消息类型进行分支处理。
            switch messageType {
                // 如果是 LibboxMessageTypeProfileContentRequest 类型（请求配置文件内容），创建一个异步任务处理该请求。
            case LibboxMessageTypeProfileContentRequest:
                Task {
                    try await processProfileContentRequest(data)
                }
                // 如果消息类型未知，抛出一个错误，表示收到了意外的消息类型。
            default:
                throw NSError(domain: "unexpected message type \(messageType)", code: 0)
            }
        }
        
        /// 处理配置文件内容请求的方法
        private func processProfileContentRequest(_ data: Data) async throws {
            // 使用 LibboxDecodeProfileContentRequest 解码请求数据。
            var error: NSError?
            let request = LibboxDecodeProfileContentRequest(data, &error)
            // 如果解码过程中出现错误，抛出该错误。
            if let error {
                throw error
            }
            // 根据请求中的 profileID 异步获取配置文件。
            let profile = try await ProfileManager.get(request!.profileID)
            // 如果找不到配置文件，抛出错误。
            guard let profile else {
                throw NSError(domain: "profile not found", code: 0)
            }
            // 创建一个 LibboxProfileContent 实例，设置名称。
            let content = LibboxProfileContent()
            // 根据配置文件的类型（本地、iCloud 或远程）设置内容类型。
            content.name = profile.name
            switch profile.type {
            case .local:
                content.type = LibboxProfileTypeLocal
            case .icloud:
                content.type = LibboxProfileTypeiCloud
            case .remote:
                content.type = LibboxProfileTypeRemote
            }
            // 读取配置文件内容并设置到 content.config。
            content.config = try profile.read()
            // 如果配置文件不是本地类型，设置远程 URL。
            if profile.type != .local {
                content.remotePath = profile.remoteURL!
            }
            // 如果配置文件是远程类型，设置自动更新相关属性和最后更新时间。
            if profile.type == .remote {
                content.autoUpdate = profile.autoUpdate
                content.autoUpdateInterval = profile.autoUpdateInterval
                if let lastUpdated = profile.lastUpdated {
                    content.lastUpdated = Int64(lastUpdated.timeIntervalSince1970)
                }
            }
            // 将编码后的配置文件内容写入连接，发送给客户端。
            try connection.write(content.encode())
        }
        
        // 写入配置文件预览列表的方法
        private func writeProfilePreviewList() async throws {
            // 异步获取所有配置文件列表。
            let profiles = try await ProfileManager.list()
            // 创建一个 LibboxProfileEncoder 实例用于编码预览列表。
            let encoder = LibboxProfileEncoder()
            for profile in profiles {
                let preview = LibboxProfilePreview()
                preview.profileID = profile.mustID
                preview.name = profile.name
                switch profile.type {
                case .local:
                    preview.type = LibboxProfileTypeLocal
                case .icloud:
                    preview.type = LibboxProfileTypeiCloud
                case .remote:
                    preview.type = LibboxProfileTypeRemote
                }
                encoder.append(preview)
            }
            // 将编码后的预览列表写入连接，发送给客户端。
            try connection.write(encoder.encode())
        }
        /// 写入错误信息的方法
        private func writeError(_ message: String) {
            // 创建一个 LibboxErrorMessage 实例，设置错误消息。
            let errorMessage = LibboxErrorMessage()
            // 尝试将编码后的错误消息写入连接，发送给客户端。
            errorMessage.message = message
            // 使用 try? 表示如果写入失败，忽略错误（因为已经在错误处理流程中）。
            try? connection.write(errorMessage.encode())
        }
    }
}
