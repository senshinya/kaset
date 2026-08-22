import Foundation

// MARK: - YouTubeChannel

/// A YouTube channel as it appears in search results and on watch pages.
struct YouTubeChannel: Identifiable, Hashable {
    let channelId: String
    let name: String
    /// Channel handle, e.g. "@veritasium".
    let handle: String?
    /// Display subscriber count, e.g. "20.8M subscribers".
    let subscriberCountText: String?
    let descriptionSnippet: String?
    let thumbnailURL: URL?

    var id: String {
        self.channelId
    }

    init(
        channelId: String,
        name: String,
        handle: String? = nil,
        subscriberCountText: String? = nil,
        descriptionSnippet: String? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.channelId = channelId
        self.name = name
        self.handle = handle
        self.subscriberCountText = subscriberCountText
        self.descriptionSnippet = descriptionSnippet
        self.thumbnailURL = thumbnailURL
    }
}

// MARK: - YouTubeChannelSortOption

/// One sort chip from a channel's Videos tab ("Latest", "Popular", "Oldest").
///
/// YouTube issues each chip a browse continuation token rather than a stable
/// params value, so the order is re-fetched by replaying the server's own
/// token instead of a constant this app would have to guess.
struct YouTubeChannelSortOption: Identifiable, Hashable {
    /// Localized chip title as YouTube rendered it.
    let title: String
    /// Browse continuation token that reloads the grid in this order.
    let continuation: String
    /// Whether YouTube marked this chip as the active order.
    let isSelected: Bool

    var id: String {
        self.title
    }
}

// MARK: - YouTubeChannelDetail

/// A channel page: metadata plus the first page of its Videos tab.
struct YouTubeChannelDetail: Hashable {
    let channel: YouTubeChannel
    let videos: [YouTubeVideo]
    /// Token for the next page of videos, or `nil` when exhausted.
    let videosContinuation: String?
    /// Sort chips offered by the Videos tab, in YouTube's order.
    let sortOptions: [YouTubeChannelSortOption]
    /// Browse `params` for this channel's Search tab, when the page exposes it.
    let searchParams: String?
    /// Whether the signed-in user subscribes to this channel
    /// (nil when the page did not expose a subscribe state).
    let isSubscribed: Bool?

    init(
        channel: YouTubeChannel,
        videos: [YouTubeVideo],
        videosContinuation: String? = nil,
        sortOptions: [YouTubeChannelSortOption] = [],
        searchParams: String? = nil,
        isSubscribed: Bool? = nil
    ) {
        self.channel = channel
        self.videos = videos
        self.videosContinuation = videosContinuation
        self.sortOptions = sortOptions
        self.searchParams = searchParams
        self.isSubscribed = isSubscribed
    }
}
