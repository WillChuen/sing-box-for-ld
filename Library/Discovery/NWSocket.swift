import Foundation
import Libbox
import Network

/// 定义一个公开的 NWSocket 类，可被其他模块访问。
public class NWSocket {
    /// 声明一个私有常量属性 connection，类型为 NWConnection，用于存储与网络端点的连接。这是一个封装，外部代码不能直接访问这个连接对象。
    private let connection: NWConnection
    /// 定义一个公开的初始化方法，接收一个 NWConnection 参数。
    public init(_ connection: NWConnection) {
        self.connection = connection
    }
    ///  定义一个可能抛出错误的公开方法 read，返回类型为 Data。
    public func read() throws -> Data {
        // 创建一个初始值为 0 的 DispatchSemaphore。这个信号量用于在异步网络操作完成前阻塞当前线程。
        let semaphore = DispatchSemaphore(value: 0)
        // 声明一个可变的隐式解包可选类型变量 result，类型为 Result<Data, Error>，用于存储异步操作的结果。
        var result: Result<Data, Error>!
        // 在连接上接收数据，要求接收 2 字节的数据（不多也不少）。
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { content, _, _, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(content!)
            }
            // 如果接收成功，释放信号量，允许阻塞的线程继续执行。
            semaphore.signal()
        }
        // 阻塞当前线程，直到信号量被释放。
        semaphore.wait()
        // 从 result 中提取数据或抛出错误，并将结果存储在 lengthChunk 中。这是包含长度信息的 2 字节数据。
        let lengthChunk = try result.get()
        // 使用 LibboxDecodeLengthChunk 函数解码长度数据块，并转换为 Int 类型。这表示接下来要接收的实际数据长度。
        let length = Int(LibboxDecodeLengthChunk(lengthChunk))
        // 再次在连接上接收数据，这次要求接收之前解码得到的长度的数据。
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { content, _, _, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(content!)
            }
            semaphore.signal()
        }
        semaphore.wait()
        // 返回从第二次接收操作中获取的数据，如果有错误则抛出。
        return try result.get()
    }
    
    /// write 方法
    public func write(_ data: Data?) throws {
        guard let data else {
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Error?
        // 通过连接发送数据，使用 LibboxEncodeChunkedMessage 函数对数据进行编码。
        // isComplete: false 表示这可能不是最后一条消息。
        // 使用 .contentProcessed 回调处理发送结果。
        connection.send(content: LibboxEncodeChunkedMessage(data), isComplete: false, completion: .contentProcessed { error in
            result = error
            semaphore.wait()
        })
        if let result {
            throw result
        }
    }
    /// 定义一个公开方法 send，接收一个可选的 Data 参数，与 write 不同，这个方法不抛出错误
    public func send(_ data: Data?) {
        guard let data else {
            return
        }
        connection.send(content: LibboxEncodeChunkedMessage(data), completion: .idempotent)
    }

    public func cancel() {
        connection.cancel()
    }
}
