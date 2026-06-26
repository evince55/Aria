import Foundation
import os.log

final class CoverFallbackService {
    private let baseURL: URL
    private let session: URLSession
    private let log = Logger(subsystem: "com.aria.music", category: "CoverFallback")

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetch(title: String, artist: String?, album: String?) async -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/cover"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "title", value: title)]
        if let artist, !artist.isEmpty { queryItems.append(URLQueryItem(name: "artist", value: artist)) }
        if let album, !album.isEmpty { queryItems.append(URLQueryItem(name: "album", value: album)) }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        let jsonData: Data
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            jsonData = data
        } catch {
            log.error("Cover fetch network error: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        struct CoverResponse: Decodable { let url: String? }
        guard let parsed = try? JSONDecoder().decode(CoverResponse.self, from: jsonData),
              let coverURLString = parsed.url,
              let coverURL = URL(string: coverURLString) else {
            return nil
        }

        let imageData: Data
        do {
            let (data, response) = try await session.data(from: coverURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return nil
            }
            imageData = data
        } catch {
            log.error("Cover image download error: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(detectExtension(from: imageData))
        do {
            try imageData.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            log.error("Cover write error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func detectExtension(from data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        return "img"
    }
}
