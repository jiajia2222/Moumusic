#if os(iOS)
import Foundation

/// Live-room chat (danmaku) over Bilibili's websocket (`wss://…/sub`, protover 2 = zlib frames).
/// Packet layout: 4 B length, 2 B header length (16), 2 B version, 4 B operation, 4 B sequence.
final class BiliLiveDanmakuClient: @unchecked Sendable {
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    func start(roomID: Int, cookie: String?, onMessage: @escaping @MainActor (String, Int) -> Void) {
        stop()
        runTask = Task.detached { [weak self] in
            var delay: UInt64 = 2_000_000_000
            while !Task.isCancelled {
                await self?.runOnce(roomID: roomID, cookie: cookie, onMessage: onMessage)
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 15_000_000_000)
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func runOnce(roomID: Int, cookie: String?, onMessage: @escaping @MainActor (String, Int) -> Void) async {
        guard let config = await BilibiliAPI.shared.liveDanmakuConfig(roomID: roomID, cookie: cookie),
              let url = URL(string: "wss://\(config.host):\(config.port)/sub") else {
            await MainActor.run {
                DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩直播", message: "弹幕服务器信息获取失败", detail: "room=\(roomID)")
            }
            return
        }
        var request = URLRequest(url: url)
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        var auth: [String: Any] = ["uid": 0, "roomid": roomID, "protover": 2, "platform": "web", "type": 2, "key": config.token]
        if let buvid = config.buvid { auth["buvid"] = buvid }
        guard let body = try? JSONSerialization.data(withJSONObject: auth),
              (try? await socket.send(.data(Self.packet(operation: 7, body: body)))) != nil else {
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                try? await socket.send(.data(Self.packet(operation: 2, body: Data("[object Object]".utf8))))
            }
        }
        defer {
            heartbeat.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { return }
            if case .data(let data) = message { await handle(data, onMessage) }
        }
    }

    private static func packet(operation: UInt32, body: Data) -> Data {
        var data = Data()
        func u32(_ value: UInt32) {
            data.append(contentsOf: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        func u16(_ value: UInt16) {
            data.append(contentsOf: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        u32(UInt32(16 + body.count))
        u16(16)
        u16(1)
        u32(operation)
        u32(1)
        data.append(body)
        return data
    }

    private func handle(_ data: Data, _ onMessage: @escaping @MainActor (String, Int) -> Void) async {
        let bytes = [UInt8](data)
        func u32(_ index: Int) -> Int {
            (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16) | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
        }
        func u16(_ index: Int) -> Int { (Int(bytes[index]) << 8) | Int(bytes[index + 1]) }
        var offset = 0
        while offset + 16 <= bytes.count {
            let length = u32(offset), headerLength = u16(offset + 4), version = u16(offset + 6), operation = u32(offset + 8)
            guard length >= headerLength, headerLength >= 16, offset + length <= bytes.count else { break }
            let body = Data(bytes[(offset + headerLength)..<(offset + length)])
            if operation == 5 {
                if version == 2 {
                    // zlib stream: drop the 2-byte header, the rest is raw deflate.
                    if body.count > 2,
                       let inflated = try? (Data(body.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data {
                        await handle(inflated, onMessage)
                    }
                } else {
                    await dispatch(body, onMessage)
                }
            }
            offset += length
        }
    }

    private func dispatch(_ body: Data, _ onMessage: @escaping @MainActor (String, Int) -> Void) async {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let command = object["cmd"] as? String, command.hasPrefix("DANMU_MSG"),
              let info = object["info"] as? [Any], info.count > 1,
              let text = info[1] as? String, !text.isEmpty else { return }
        let color = ((info[0] as? [Any])?.dropFirst(3).first as? NSNumber)?.intValue ?? 0xFFFFFF
        await onMessage(text, color)
    }
}
#endif
