import Foundation

/// Base HTTP client for all Supabase REST API calls.
///
/// Backend: https://uvoxbqqxrsqjdcljhjvk.supabase.co
/// Auth:    Supabase Auth v2, email + password, Bearer JWT
final class APIClient {

    static let shared = APIClient()

    // MARK: - Configuration (real production values)

    let baseURL = "https://uvoxbqqxrsqjdcljhjvk.supabase.co"

    let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" +
        ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV2b3hicXF4cnNxamRjbGpoanZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYxODc0NzAsImV4cCI6MjA5MTc2MzQ3MH0" +
        ".Z90WFApwYZmpJqlytKMH140RrXntLbRFQMlEwLvMcAU"

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    // MARK: - Request Building

    func request(
        path: String,
        method: String = "GET",
        body: Encodable? = nil,
        authToken: String? = nil,
        queryItems: [URLQueryItem]? = nil,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token = authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            req.httpBody = try JSONEncoder().encode(body)
        }

        return req
    }

    // MARK: - Execution

    func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder.supabase.decode(T.self, from: data)
        } catch let decodeError {
            throw APIError.decodingError(decodeError)
        }
    }

    func perform(_ request: URLRequest) async throws {
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Validation

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidResponse: return "Invalid server response."
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        }
    }
}

// MARK: - JSONDecoder

extension JSONDecoder {
    /// Shared decoder configured for Supabase responses:
    ///   - snake_case column names → camelCase Swift properties
    ///   - ISO 8601 timestamps with fractional seconds
    static let supabase: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = withFrac.date(from: s) { return date }
            if let date = withoutFrac.date(from: s) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date: \(s)")
            )
        }
        return d
    }()
}
