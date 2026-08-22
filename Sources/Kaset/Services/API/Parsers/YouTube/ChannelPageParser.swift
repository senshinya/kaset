import Foundation

/// Parses YouTube channel pages (`browse` with a `UC…` browse ID).
///
/// Channel metadata comes from `metadata.channelMetadataRenderer` (stable
/// across header redesigns). Videos come from the **Videos** tab rather than
/// the landing tab: the landing tab only returns a curated subset of shelves
/// with no usable grid continuation, so browsing it can never reach a
/// channel's full catalog.
enum ChannelPageParser {
    /// InnerTube browse `params` selecting a channel's Videos tab.
    /// Verified with `swift run api-explorer --youtube browse <UC…> <params>`.
    static let videosTabParams = "EgZ2aWRlb3PyBgQKAjoA"

    /// Fallback browse `params` selecting a channel's Search tab, used when a
    /// response omits the tab list. Real pages carry their own value, which
    /// `searchParams(of:)` prefers.
    static let searchTabParams = "EgZzZWFyY2jyBgQKAloA"

    /// Untranslated tab name encoded inside the Search tab's `params`.
    private static let searchTabName = "search"

    static func parse(_ data: [String: Any], channelId fallbackChannelId: String) -> YouTubeChannelDetail? {
        let metadata = (data["metadata"] as? [String: Any])?["channelMetadataRenderer"]
            as? [String: Any]

        let channelId = metadata?["externalId"] as? String ?? fallbackChannelId
        guard let name = metadata?["title"] as? String else {
            return nil
        }

        let channel = YouTubeChannel(
            channelId: channelId,
            name: name,
            handle: Self.handle(fromVanityURL: metadata?["vanityChannelUrl"] as? String),
            subscriberCountText: Self.subscriberCountText(of: data),
            descriptionSnippet: metadata?["description"] as? String,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: metadata?["avatar"])
        )

        var videos: [YouTubeVideo] = []
        var continuation: String?
        if let contents = data["contents"] {
            YouTubeFeedParser.collect(
                in: contents,
                videos: &videos,
                continuation: &continuation
            )
        }

        return YouTubeChannelDetail(
            channel: channel,
            videos: YouTubeFeedParser.deduplicate(videos),
            videosContinuation: continuation,
            sortOptions: Self.sortOptions(of: data),
            searchParams: Self.searchParams(of: data),
            isSubscribed: Self.isSubscribed(in: data)
        )
    }

    // MARK: - Sort Chips

    /// Sort chips from the Videos tab's grid header
    /// (`richGridRenderer.header.chipBarViewModel.chips[].chipViewModel`).
    ///
    /// Each chip carries a browse continuation token that reloads the grid in
    /// that order, so ordering replays YouTube's own tokens instead of
    /// guessing a params constant.
    static func sortOptions(of data: [String: Any]) -> [YouTubeChannelSortOption] {
        guard let contents = data["contents"],
              let chips = firstChipBarChips(in: contents)
        else {
            return []
        }

        var options: [YouTubeChannelSortOption] = []
        var seen = Set<String>()
        for entry in chips {
            guard let chip = entry["chipViewModel"] as? [String: Any],
                  let title = chip["text"] as? String,
                  !title.isEmpty,
                  let token = Self.continuationToken(ofChip: chip),
                  seen.insert(title).inserted
            else {
                continue
            }
            options.append(
                YouTubeChannelSortOption(
                    title: title,
                    continuation: token,
                    isSelected: chip["selected"] as? Bool ?? false
                )
            )
        }
        return options
    }

    /// Browse `params` for this channel's Search tab, read from the response's
    /// own tab list so channel-specific tab sets (Live, Courses, …) are
    /// tolerated. Matched on the untranslated name inside the params, never on
    /// the localized tab title.
    static func searchParams(of data: [String: Any]) -> String? {
        for tab in self.tabs(of: data) {
            guard let params = (
                (tab["endpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
            )?["params"] as? String else {
                continue
            }
            // YouTube percent-encodes the trailing base64 padding in tab endpoints.
            let decoded = params.removingPercentEncoding ?? params
            if Self.tabName(fromParams: decoded) == Self.searchTabName {
                return decoded
            }
        }
        return nil
    }

    /// The untranslated tab name a browse `params` value selects.
    ///
    /// Tab params are base64 protobuf that lead with the tab's English name
    /// ("videos", "search", "playlists"), which is the only
    /// language-independent way to tell tabs apart.
    static func tabName(fromParams params: String) -> String? {
        var base64 = params
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) {
            base64.append("=")
        }
        guard let bytes = Data(base64Encoded: base64), bytes.count >= 2 else {
            return nil
        }
        // Field 2, wire type 2 (length-delimited string).
        guard bytes[0] == 0x12 else {
            return nil
        }
        let length = Int(bytes[1])
        guard length > 0, bytes.count >= 2 + length else {
            return nil
        }
        return String(data: bytes[2 ..< (2 + length)], encoding: .utf8)
    }

    // MARK: - Subscribe State

    /// Whether the signed-in viewer subscribes to this channel.
    ///
    /// Channel pages moved from the legacy `subscribeButtonRenderer` to a
    /// `subscribeButtonViewModel` whose state usually lives in the response's
    /// entity store, so all three shapes are checked. Returns `nil` when the
    /// page exposes no subscribe state at all (signed out).
    ///
    /// Only `header` is searched. `contents` carries subscribe buttons for
    /// recommended channels (`gridChannelRenderer.subscribeButton`), and since
    /// dictionary traversal order is unspecified, a whole-response walk could
    /// pick a different channel's button on any given run.
    static func isSubscribed(in data: [String: Any]) -> Bool? {
        let header = data["header"] ?? [:]
        let button = Self.firstDictionary(in: header) { dict in
            dict["subscribeButtonViewModel"] as? [String: Any]
                ?? dict["subscribeButtonRenderer"] as? [String: Any]
        }

        // No button in the header means this channel exposes no subscribe
        // state; an entity found elsewhere would belong to some other channel.
        guard let button else {
            return nil
        }

        if let subscribed = button["subscribed"] as? Bool {
            return subscribed
        }

        return Self.subscriptionStateEntity(in: data, key: Self.entityKey(ofButton: button))
    }

    /// The entity-store key a subscribe button points at.
    ///
    /// The field has been spelled both ways across renderer generations and
    /// this app cannot verify the signed-in shape from a signed-out probe, so
    /// both names are accepted rather than betting on one.
    private static func entityKey(ofButton button: [String: Any]) -> String? {
        for name in ["subscribedEntityKey", "stateEntityStoreKeyId"] {
            if let key = button[name] as? String, !key.isEmpty {
                return key
            }
        }
        return nil
    }

    /// Reads `subscribed` from the response's `subscriptionStateEntity`
    /// mutations.
    ///
    /// A page carries entities for recommended channels too, so a wrong match
    /// would show the wrong button state and send subscribe/unsubscribe the
    /// wrong way. When the button names its entity, only that exact entity
    /// counts; the lone-entity fallback is for pages whose button names none.
    private static func subscriptionStateEntity(in data: [String: Any], key: String?) -> Bool? {
        guard let updates = data["frameworkUpdates"] as? [String: Any],
              let batch = updates["entityBatchUpdate"] as? [String: Any],
              let mutations = batch["mutations"] as? [[String: Any]]
        else {
            return nil
        }

        var candidates: [Bool] = []
        for mutation in mutations {
            guard let payload = mutation["payload"] as? [String: Any],
                  let entity = payload["subscriptionStateEntity"] as? [String: Any]
            else {
                continue
            }
            if let key {
                let entityKey = entity["key"] as? String ?? mutation["entityKey"] as? String
                if entityKey == key {
                    return entity["subscribed"] as? Bool
                }
                continue
            }
            if let subscribed = entity["subscribed"] as? Bool {
                candidates.append(subscribed)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Private

    /// Extracts "@handle" from "http://www.youtube.com/@handle".
    private static func handle(fromVanityURL url: String?) -> String? {
        guard let last = url?.split(separator: "/").last, last.hasPrefix("@") else {
            return nil
        }
        return String(last)
    }

    /// Best-effort subscriber count from the page header
    /// (e.g. "20.8M subscribers" somewhere in `header`).
    private static func subscriberCountText(of data: [String: Any]) -> String? {
        guard let header = data["header"] else { return nil }
        return Self.firstText(in: header) { $0.localizedCaseInsensitiveContains("subscriber") }
    }

    /// The response's browse tabs, covering both renderer generations.
    private static func tabs(of data: [String: Any]) -> [[String: Any]] {
        guard let results = (data["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"]
            as? [String: Any],
            let tabs = results["tabs"] as? [[String: Any]]
        else {
            return []
        }
        return tabs.compactMap { tab in
            tab["tabRenderer"] as? [String: Any] ?? tab["expandableTabRenderer"] as? [String: Any]
        }
    }

    private static func continuationToken(ofChip chip: [String: Any]) -> String? {
        let command = (
            (chip["tapCommand"] as? [String: Any])?["innertubeCommand"] as? [String: Any]
        )?["continuationCommand"] as? [String: Any]
        guard let token = command?["token"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Depth-first search for the first `chipBarViewModel`'s chips.
    private static func firstChipBarChips(in value: Any) -> [[String: Any]]? {
        self.firstDictionary(in: value) { $0["chipBarViewModel"] as? [String: Any] }?["chips"]
            as? [[String: Any]]
    }

    /// Depth-first search for the first dictionary a transform accepts.
    private static func firstDictionary(
        in value: Any,
        matching transform: ([String: Any]) -> [String: Any]?
    ) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let match = transform(dict) {
                return match
            }
            for nested in dict.values {
                if let found = Self.firstDictionary(in: nested, matching: transform) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstDictionary(in: element, matching: transform) {
                    return found
                }
            }
        }
        return nil
    }

    /// Depth-first search for the first metadata text matching a predicate.
    private static func firstText(
        in value: Any,
        where predicate: (String) -> Bool
    ) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["content", "simpleText", "text"] {
                if let text = dict[key] as? String, predicate(text) {
                    return text
                }
            }
            for nested in dict.values {
                if let found = firstText(in: nested, where: predicate) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstText(in: element, where: predicate) {
                    return found
                }
            }
        }
        return nil
    }
}
