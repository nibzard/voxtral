import Foundation

final class GeminiRewriteService {
    struct Configuration {
        var apiKey: String
        var model: String = "gemini-2.0-flash-exp"
        var apiEndpoint: String = "generativelanguage.googleapis.com"
        var apiPath: String = "/v1beta/models/\(model):generateContent"
        var timeout: TimeInterval = 30.0
    }

    struct RewriteRequest {
        var transcript: String
        var configuration: Configuration
    }

    struct RewriteResponse {
        let rewrittenText: String
        let originalText: String
    }

    enum RewriteError: LocalizedError {
        case invalidAPIKey
        case networkError(Error)
        case invalidResponse
        case rateLimitExceeded
        case serverError(Int)
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey:
                return "Invalid Gemini API key"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from Gemini"
            case .rateLimitExceeded:
                return "Gemini API rate limit exceeded"
            case .serverError(let code):
                return "Gemini server error (HTTP \(code))"
            case .unknown(let message):
                return message
            }
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: Configuration) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.timeout
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func rewrite(_ request: RewriteRequest) async throws -> RewriteResponse {
        AppLogger.shared.logRewriteStarted()

        let requestBody = GeminiRequest(
            contents: [
                Content(
                    parts: [
                        Part(text: rewritePrompt + "\n\n" + request.transcript)
                    ]
                )
            ]
        )

        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonData = try encoder.encode(requestBody)

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = configuration.apiEndpoint
        urlComponents.path = "/v1beta/models/\(configuration.model):generateContent"
        urlComponents.queryItems = [
            URLQueryItem(name: "key", value: configuration.apiKey)
        ]

        guard let url = urlComponents.url else {
            throw RewriteError.unknown("Invalid URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = jsonData

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RewriteError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200...299:
                break
            case 401:
                throw RewriteError.invalidAPIKey
            case 429:
                throw RewriteError.rateLimitExceeded
            case 500...599:
                throw RewriteError.serverError(httpResponse.statusCode)
            default:
                throw RewriteError.serverError(httpResponse.statusCode)
            }

            let geminiResponse = try decoder.decode(GeminiResponse.self, from: data)

            guard let text = geminiResponse.candidates.first?.content.parts.first?.text else {
                throw RewriteError.invalidResponse
            }

            AppLogger.shared.logRewriteCompleted()
            return RewriteResponse(
                rewrittenText: text,
                originalText: request.transcript
            )
        } catch {
            AppLogger.shared.logRewriteError(error)
            throw error
        }
    }

    private var rewritePrompt: String {
        """
        You are a transcription fixer. Your task is to:
        1. Correct obvious speech-to-text errors
        2. Fix grammar and punctuation
        3. Format as clean Markdown
        4. Preserve the original meaning
        5. Do not add new facts or information
        6. Keep the original structure when possible

        The transcript below is a raw transcription with timestamps. Return only the cleaned transcript without the timestamps, formatted as Markdown.
        """
    }
}

private struct GeminiRequest: Codable {
    let contents: [Content]
}

private struct Content: Codable {
    let parts: [Part]
}

private struct Part: Codable {
    let text: String
}

private struct GeminiResponse: Codable {
    let candidates: [Candidate]

    enum CodingKeys: String, CodingKey {
        case candidates
    }
}

private struct Candidate: Codable {
    let content: Content

    enum CodingKeys: String, CodingKey {
        case content
    }
}
