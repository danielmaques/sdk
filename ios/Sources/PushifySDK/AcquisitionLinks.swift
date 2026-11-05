import Foundation
import UIKit

/// A resolved acquisition link. The host application decides how to navigate to `destination`.
public struct PushifyAcquisitionLink: Decodable, Sendable {
    public let object: String
    public let status: String
    public let linkId: String
    public let name: String
    public let slug: String
    public let destination: String
    public let appScheme: String
    public let campaign: [String: String]
    public let attributed: Bool

    enum CodingKeys: String, CodingKey {
        case object, status, name, slug, destination, campaign, attributed
        case appScheme = "app_scheme"
        case linkId = "link_id"
    }
}

/// Captures and resolves Pushify app-link tokens without taking over app navigation.
public final class PushifyAcquisitionLinks: Sendable {
    private let publicApiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(publicApiKey: String, apiBaseURL: URL = URL(string: "https://api.pushify.app")!, session: URLSession = .shared) throws {
        guard !publicApiKey.isEmpty, apiBaseURL.scheme == "https",
              let endpoint = URL(string: "/v1/acquisition_links/resolve", relativeTo: apiBaseURL)?.absoluteURL else {
            throw AcquisitionLinkError.invalidConfiguration
        }
        self.publicApiKey = publicApiKey
        self.endpoint = endpoint
        self.session = session
    }

    /// Extracts the direct `rdt` token from a Pushify app URL.
    public func token(from url: URL) -> String? {
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "rdt" })?.value,
              Self.isValid(token) else { return nil }
        return token
    }

    /// Extracts and resolves a direct app URL in one call. Returns `nil` when it is not a Pushify link.
    public func resolve(url: URL, appUserID: String? = nil) async throws -> PushifyAcquisitionLink? {
        guard let token = token(from: url) else { return nil }
        return try await resolve(token, appUserID: appUserID)
    }

    /// Reads and consumes a Pushify deferred token from the pasteboard after the app has explained this action to the user.
    /// The system may show a pasteboard privacy prompt. This method never reads unrelated clipboard content.
    @MainActor
    public func consumeDeferredTokenFromPasteboard() -> String? {
        guard let value = UIPasteboard.general.string,
              Self.isValid(value), value.hasPrefix("rdit_") else { return nil }
        UIPasteboard.general.string = nil
        return value
    }

    /// Reads and resolves a deferred pasteboard handoff after an explicit user action.
    @MainActor
    public func resolveDeferredPasteboard(appUserID: String? = nil) async throws -> PushifyAcquisitionLink? {
        guard let token = UIPasteboard.general.string,
              Self.isValid(token), token.hasPrefix("rdit_") else { return nil }
        let link = try await resolve(token, appUserID: appUserID)
        if UIPasteboard.general.string == token { UIPasteboard.general.string = nil }
        return link
    }

    /// Resolves a direct or deferred opaque token. Pass the SDK's current app user id when known.
    public func resolve(_ token: String, appUserID: String? = nil) async throws -> PushifyAcquisitionLink {
        guard Self.isValid(token) else { throw AcquisitionLinkError.invalidToken }
        var body: [String: String] = ["token": token]
        if let appUserID, !appUserID.isEmpty { body["app_user_id"] = appUserID }
        let requestBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0...2 {
            var request = URLRequest(url: endpoint, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("Bearer \(publicApiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = requestBody

            do {
                let (data, response) = try await session.data(for: request)
                guard data.count <= 65_536 else { throw AcquisitionLinkError.resolutionFailed }
                guard let response = response as? HTTPURLResponse else {
                    throw AcquisitionLinkError.resolutionFailed
                }
                if (response.statusCode == 429 || response.statusCode >= 500), attempt < 2 {
                    try await Self.waitBeforeRetry(attempt)
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw AcquisitionLinkError.resolutionFailed
                }
                return try JSONDecoder().decode(PushifyAcquisitionLink.self, from: data)
            } catch let error as URLError where error.code != .cancelled && attempt < 2 {
                try await Self.waitBeforeRetry(attempt)
            }
        }
        throw AcquisitionLinkError.resolutionFailed
    }

    private static func waitBeforeRetry(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: attempt == 0 ? 250_000_000 : 750_000_000)
    }

    private static func isValid(_ token: String) -> Bool {
        token.range(of: #"^(rdlt|rdit)_[A-Za-z0-9_-]{30,80}$"#, options: .regularExpression) != nil
    }
}

public enum AcquisitionLinkError: Error, Sendable {
    case invalidConfiguration
    case invalidToken
    case resolutionFailed
}
