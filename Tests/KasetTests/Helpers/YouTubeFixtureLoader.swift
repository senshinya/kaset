import Foundation

// MARK: - Fixture Loading

/// Loads a captured YouTube API fixture from the test bundle.
func loadYouTubeFixture(_ name: String) throws -> [String: Any] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw YouTubeFixtureError.notFound(name)
    }
    let data = try Data(contentsOf: url)
    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw YouTubeFixtureError.invalidJSON(name)
    }
    return dict
}

// MARK: - YouTubeFixtureError

enum YouTubeFixtureError: Error {
    case notFound(String)
    case invalidJSON(String)
}
