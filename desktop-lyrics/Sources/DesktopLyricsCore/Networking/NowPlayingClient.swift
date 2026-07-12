import Foundation

public enum NowPlayingClientError: Error {
    case badStatus(Int)
    case decodeFailed(Error)
}

// 轮询 relay 的 /now(公开、无需鉴权,同一个接口网页版也在用)。这是采集器唯一对外
// 暴露的数据出口——collector 本身没有本地 IPC/端口,一切都要走公网这一条路。
public final class NowPlayingClient {
    private let session: URLSession
    private let baseURL: String

    public init(baseURL: String, timeout: TimeInterval = 6) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public func fetchNow() async throws -> NowPlayingState {
        guard let url = URL(string: "\(baseURL)/now") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NowPlayingClientError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(NowPlayingState.self, from: data)
        } catch {
            throw NowPlayingClientError.decodeFailed(error)
        }
    }
}
