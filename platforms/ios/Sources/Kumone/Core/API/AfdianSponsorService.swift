import Foundation

/// Public, redacted sponsor data exposed by Moumusic's server-side Afdian
/// adapter. The Afdian token never enters the app.
actor AfdianSponsorService {
    static let shared = AfdianSponsorService()

    struct Sponsor: Codable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let avatar: String?
        let plan: String?
        let amount: Double?
        let lastSupportTime: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, avatar, plan, amount, lastSupportTime
        }
    }

    struct Stats: Codable, Sendable {
        let supporterCount: Int
        let recentSupportAt: Int?
        let showAmount: Bool
        let totalAmount: Double?
    }

    struct Snapshot: Sendable {
        let sponsors: [Sponsor]
        let stats: Stats
    }

    enum ServiceError: LocalizedError {
        case invalidResponse
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "赞助数据格式不正确"
            case .unavailable: return "暂时无法获取赞助名单"
            }
        }
    }

    private let baseURL = URL(string: "https://music.nadev.xyz/api/aifadian")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func load() async throws -> Snapshot {
        async let sponsors: [Sponsor] = fetch(path: "sponsors", key: "supporters")
        async let stats: Stats = fetch(path: "stats", key: "stats")
        do {
            return Snapshot(sponsors: try await sponsors, stats: try await stats)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceError.unavailable
        }
    }

    private func fetch<Value: Decodable>(path: String, key: String) async throws -> Value {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Moumusic-iOS", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceError.unavailable
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw ServiceError.unavailable
        }
        guard let envelope = try? decoder.decode(Envelope<Value>.self, from: data), envelope.success else {
            throw ServiceError.invalidResponse
        }
        return envelope.value(for: key)
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let success: Bool
        let supporters: [Sponsor]?
        let stats: Stats?

        func value(for key: String) throws -> Value {
            if key == "supporters", let supporters {
                return supporters as! Value
            }
            if key == "stats", let stats {
                return stats as! Value
            }
            throw ServiceError.invalidResponse
        }
    }
}
