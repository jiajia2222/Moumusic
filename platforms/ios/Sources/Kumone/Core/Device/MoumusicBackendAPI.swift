#if os(iOS)
import Foundation

/// 服务端错误码 → 用户可读文案（与 Beans 2.0.2 的 DeviceReporter 保持一致）。
struct BackendError: LocalizedError {
    let code: String
    let httpStatus: Int
    let serverMessage: String

    var errorDescription: String? {
        switch code {
        case "developer_unauthorized": return "当前设备没有开发者权限。"
        case "invalid_public_user_id":
            return httpStatus == 400 && serverMessage.contains("device") ? "设备标识无效，请重启应用后重试。" : "用户 ID 最多 24 个字符，不能包含空格。"
        case "public_user_id_taken": return "这个用户 ID 已被其他设备使用。"
        case "device_not_found": return "没有找到这个设备，请确认对方已经启动过软件。"
        case "missing_required_fields": return "请填写全部必填项。"
        case "too_many_attachments": return "最多只能上传 4 个附件。"
        case "attachment_too_large": return "单个附件不能超过 50 MB。"
        case "attachment_upload_failed": return "附件上传失败，文件可能过大或数量超出限制。"
        case "unsupported_attachment": return "不支持这个文件类型，请选择 JS、图片、视频或普通文件。"
        case "invalid_response": return "服务器返回异常，请稍后重试。"
        case "not_found" where httpStatus == 404 && serverMessage.isEmpty: return "服务器尚未部署对应接口，请先更新后台服务。"
        default: return "服务器处理失败，请稍后重试。"
        }
    }
}

struct BackendAttachment {
    let filename: String
    let mimeType: String
    let data: Data
}

enum MoumusicBackendAPI {
    // MARK: 基础请求

    @MainActor
    static func postJSON(_ path: String, body: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let req = MoumusicServer.request(path, method: "POST", json: body, timeout: timeout)
        return try await send(req)
    }

    @MainActor
    static func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(url: MoumusicServer.url(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw BackendError(code: obj?["error"] as? String ?? "server_error",
                               httpStatus: status,
                               serverMessage: obj?["message"] as? String ?? "")
        }
        guard let obj = obj else { throw BackendError(code: "invalid_response", httpStatus: status, serverMessage: "") }
        return obj
    }

    // MARK: 反馈

    struct FeedbackReply: Identifiable, Hashable {
        let id = UUID()
        let content: String
        let createdAt: String
    }

    struct FeedbackRecord: Identifiable, Hashable {
        let id: String
        let content: String
        let submittedAt: String
        let replies: [FeedbackReply]
    }

    @MainActor
    static func submitFeedback(content: String, contact: String, attachments: [BackendAttachment]) async throws -> String {
        let boundary = "MoumusicBoundary-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("user_id", StableDeviceID.value)
        field("content", content)
        field("contact", contact)
        for a in attachments {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"\(a.filename)\"\r\nContent-Type: \(a.mimeType)\r\n\r\n".utf8))
            body.append(a.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = MoumusicServer.request("feedback", method: "POST", timeout: 180)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let obj = try await send(req)
        return obj["feedback_id"] as? String ?? ""
    }

    @MainActor
    static func feedbackRecords() async throws -> [FeedbackRecord] {
        let obj = try await get("feedback", query: ["user_id": StableDeviceID.value])
        let rows = obj["records"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let id = r["feedback_id"] as? String else { return nil }
            let replies = (r["feedback_replies"] as? [[String: Any]] ?? []).map {
                FeedbackReply(content: $0["content"] as? String ?? "", createdAt: $0["created_at"] as? String ?? "")
            }
            return FeedbackRecord(id: id, content: r["content"] as? String ?? "", submittedAt: r["submitted_at"] as? String ?? "", replies: replies)
        }
    }

    @MainActor
    static func deleteFeedback(id: String) async throws {
        _ = try await postJSON("feedback/delete", body: ["user_id": StableDeviceID.value, "feedback_id": id])
    }

    // MARK: 开发者

    struct DeviceRecord: Identifiable, Hashable {
        var id: String { userID }
        let userID: String
        let publicID: String
        let exclusiveID: String
        let badgeStyle: String
        let deviceModel: String
        let deviceName: String
        let system: String
        let appVersion: String
        let lastSeenAt: String
    }

    private static func devRequest(_ op: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        var body = extra
        body["developer_user_id"] = StableDeviceID.value
        return try await postJSON("developer/\(op)", body: body)
    }

    private static func parseRecords(_ obj: [String: Any]) -> [DeviceRecord] {
        (obj["records"] as? [[String: Any]] ?? []).map { r in
            DeviceRecord(
                userID: r["user_id"] as? String ?? "",
                publicID: r["public_user_id"] as? String ?? "",
                exclusiveID: r["exclusive_id"] as? String ?? "",
                badgeStyle: r["badge_style"] as? String ?? "black_purple_gold",
                deviceModel: r["device_model"] as? String ?? "",
                deviceName: r["device_name"] as? String ?? "",
                system: [r["system_name"] as? String, r["system_version"] as? String].compactMap { $0 }.joined(separator: " "),
                appVersion: r["app_version"] as? String ?? "",
                lastSeenAt: r["last_seen_at"] as? String ?? ""
            )
        }
    }

    @MainActor static func developerAnnouncement() async throws -> (enabled: Bool, text: String) {
        let obj = try await get("config.json")
        return (obj["announcement_enabled"] as? Bool ?? false, obj["announcement"] as? String ?? "")
    }

    @MainActor static func saveAnnouncement(enabled: Bool, text: String) async throws {
        _ = try await devRequest("announcement", ["announcement_enabled": enabled, "announcement": text])
    }

    @MainActor static func globalDownloadEnabled() async throws -> Bool {
        let obj = try await devRequest("download-access")
        return obj["global_enabled"] as? Bool ?? false
    }

    @MainActor static func setGlobalDownload(_ enabled: Bool) async throws {
        _ = try await devRequest("download-global", ["enabled": enabled])
    }

    @MainActor static func downloadRecords() async throws -> [DeviceRecord] {
        parseRecords(try await devRequest("download-access"))
    }

    @MainActor static func grantDownload(to publicID: String, enabled: Bool) async throws {
        _ = try await devRequest("grant-download", ["target_public_user_id": publicID, "enabled": enabled])
    }

    @MainActor static func exclusiveRecords() async throws -> [DeviceRecord] {
        parseRecords(try await devRequest("exclusive-access"))
    }

    @MainActor static func grantExclusiveID(to publicID: String, assigned: String, enabled: Bool, badgeStyle: String) async throws {
        _ = try await devRequest("grant-exclusive-id", [
            "target_public_user_id": publicID,
            "assigned_public_user_id": assigned,
            "enabled": enabled,
            "badge_style": badgeStyle,
        ])
    }
}
#endif
