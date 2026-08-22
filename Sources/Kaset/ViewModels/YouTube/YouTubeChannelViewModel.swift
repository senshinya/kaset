import Foundation
import Observation

/// View model for a YouTube channel page: header, subscribe state, and the
/// channel's Videos tab with sorting, in-channel search, and pagination.
@MainActor
@Observable
final class YouTubeChannelViewModel {
    /// A list as it was last published, used to undo a failed swap.
    private struct ListSnapshot {
        var mode: Mode = .videos
        var sortTitle: String?
        var videos: [YouTubeVideo] = []
        var continuation: String?
    }

    /// Which list the grid is showing.
    enum Mode: Equatable {
        /// The channel's Videos tab, in the selected sort order.
        case videos
        /// Results of an in-channel search.
        case search(query: String)
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Loaded channel detail (header, sort chips, search params).
    private(set) var detail: YouTubeChannelDetail?

    /// Videos currently shown in the grid (sorted list or search results).
    private(set) var videos: [YouTubeVideo] = []

    /// What the grid is currently showing.
    private(set) var mode: Mode = .videos

    /// Title of the active sort chip, or `nil` before the page loads.
    private(set) var selectedSortTitle: String?

    /// Whether the signed-in user subscribes to this channel.
    private(set) var isSubscribed = false

    /// Whether the page exposed a subscribe state at all (signed out pages
    /// don't, and the button stays hidden).
    private(set) var canSubscribe = false

    /// Whether a subscribe/unsubscribe request is in flight.
    private(set) var isUpdatingSubscription = false

    /// Live text in the in-channel search field.
    var searchQuery = ""

    /// A failed sort or in-channel search. Shown beside the grid rather than
    /// replacing the page: the list it tried to replace is still valid, still
    /// on screen, and the same control can simply be used again.
    private(set) var listError: LoadingError?

    /// The last list the user actually saw. A swap clears the grid while it
    /// loads, so a second swap started before the first answers would otherwise
    /// snapshot that transient empty state and roll back to it.
    private var committed = ListSnapshot()

    /// Continuation token for the next page of the active list.
    private var continuation: String?

    /// Changes whenever pagination advances, even if the page adds no visible
    /// videos, so the grid's paging task re-fires.
    private(set) var paginationTrigger = 0

    let channelId: String
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    /// Invalidates stale list swaps (sort chip taps, searches) so a slow
    /// earlier request can never overwrite a newer list.
    private var listGeneration = 0

    /// Advances at both ends of every subscribe/unsubscribe, so a page load
    /// that overlapped the mutation is recognizable as carrying pre-mutation
    /// state and is stopped from publishing it.
    private var subscriptionGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(channelId: String, client: any YouTubeClientProtocol) {
        self.channelId = channelId
        self.client = client
    }

    var sortOptions: [YouTubeChannelSortOption] {
        self.detail?.sortOptions ?? []
    }

    var hasMoreVideos: Bool {
        self.continuation != nil
    }

    var isSearching: Bool {
        if case .search = self.mode {
            return true
        }
        return false
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        // A full load publishes a list too, so it claims a list generation up
        // front: a sort or search started while it is in flight is the newer
        // intent and must not be undone when the page finally answers.
        self.listGeneration += 1
        let listRun = self.listGeneration
        let subscriptionRun = self.subscriptionGeneration
        self.loadingState = .loading
        do {
            let detail = try await self.client.getChannel(channelId: self.channelId)
            guard generation == self.loadGeneration, listRun == self.listGeneration else { return }
            self.detail = detail
            self.videos = detail.videos
            self.continuation = detail.videosContinuation
            self.mode = .videos
            // The grid is back to the unfiltered Videos tab, so the field must
            // not keep claiming these are results for a query.
            self.searchQuery = ""
            self.selectedSortTitle = detail.sortOptions.first(where: \.isSelected)?.title
                ?? detail.sortOptions.first?.title
            self.canSubscribe = detail.isSubscribed != nil
            // A mutation that overlapped this load at any point knows more than
            // the page does: SwiftUI restarts .task during layout churn, and a
            // page fetched around a toggle still describes the pre-toggle state.
            // The generation catches loads that straddle either edge of the
            // mutation; the in-flight flag catches one that fits entirely inside.
            if subscriptionRun == self.subscriptionGeneration, !self.isUpdatingSubscription {
                self.isSubscribed = detail.isSubscribed ?? false
            }
            self.paginationTrigger += 1
            self.listError = nil
            self.commitList()
            self.loadingState = .loaded
        } catch {
            // Same fence as the success path: a sort or search that landed
            // while this load was in flight owns the screen, and a late
            // failure here must not replace its results with an error.
            guard generation == self.loadGeneration, listRun == self.listGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube channel: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    // MARK: - Paging

    func loadMore() async {
        guard self.loadingState == .loaded, let continuation = self.continuation else { return }
        let listRun = self.listGeneration

        self.loadingState = .loadingMore
        do {
            let feed = try await self.client.getFeedContinuation(continuation: continuation)
            guard listRun == self.listGeneration else { return }
            self.append(feed)
            self.commitList()
            self.loadingState = .loaded
        } catch {
            guard listRun == self.listGeneration else { return }
            // A cancelled page load is not an error; allow retrying.
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("Failed to load more channel videos: \(error.localizedDescription)")
            // Dropping the token ends the list rather than leaving a spinner
            // that nothing will re-fire: the paging task is keyed on
            // `paginationTrigger`, which only a successful page advances. This
            // is the same failed-page rule the subscriptions and history feeds
            // use; changing it belongs to all of them at once, not here alone.
            self.continuation = nil
            // The snapshot has to forget it too, or a later failed swap would
            // roll back to a list that offers this dead page again.
            self.commitList()
            self.loadingState = .loaded
        }
    }

    // MARK: - Sorting

    /// Reloads the video grid in the given order by replaying YouTube's own
    /// chip token. Clears any active search, since the sort chips belong to the
    /// Videos tab.
    func selectSort(_ option: YouTubeChannelSortOption) async {
        guard self.selectedSortTitle != option.title || self.isSearching else { return }
        await self.replaceList(mode: .videos, sortTitle: option.title, clearingQuery: true) {
            try await self.client.getFeedContinuation(continuation: option.continuation)
        }
    }

    // MARK: - In-Channel Search

    /// Runs the current `searchQuery` against this channel, or restores the
    /// Videos tab when the field is empty.
    ///
    /// Only `feed.videos` reaches the grid. The channel Search tab answers with
    /// long-form results (probed across several channels, Shorts-heavy ones
    /// included, with no Shorts renderer in any response), and Shorts have
    /// their own surface, so the split-off `feed.shorts` is intentionally
    /// unused here.
    func runSearch() async {
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await self.clearSearch()
            return
        }
        guard self.mode != .search(query: query) else { return }

        let params = self.detail?.searchParams
        await self.replaceList(mode: .search(query: query), sortTitle: nil, clearingQuery: false) {
            try await self.client.searchChannel(
                channelId: self.channelId,
                query: query,
                params: params
            )
        }
    }

    /// Drops search results and restores the Videos tab in its current order.
    func clearSearch() async {
        guard self.isSearching else {
            self.searchQuery = ""
            return
        }

        let selected = self.sortOptions.first { $0.title == self.selectedSortTitle }
        guard let selected else {
            // No chips (rare): re-fetch the page to get the default order back.
            self.searchQuery = ""
            await self.load()
            return
        }
        await self.replaceList(mode: .videos, sortTitle: nil, clearingQuery: true) {
            try await self.client.getFeedContinuation(continuation: selected.continuation)
        }
    }

    // MARK: - Subscription

    /// Subscribes/unsubscribes the channel, optimistically with rollback.
    ///
    /// One mutation at a time: overlapping toggles each capture their own
    /// pre-toggle value, so a second tap landing while the first is in flight
    /// could roll the button back to a state the server never had.
    ///
    /// The rollback is unconditional because `load()` refuses to publish
    /// subscribe state across a mutation, so nothing else can have written
    /// `isSubscribed` between the optimistic flip and the failure.
    func toggleSubscribed() async {
        guard self.canSubscribe, !self.isUpdatingSubscription else { return }

        // Both edges advance the generation so a load is fenced out whether its
        // request began before the mutation or merely before it settled: either
        // way the response was produced from pre-mutation state.
        self.subscriptionGeneration += 1
        self.isUpdatingSubscription = true
        defer {
            self.subscriptionGeneration += 1
            self.isUpdatingSubscription = false
        }

        let wasSubscribed = self.isSubscribed
        self.isSubscribed = !wasSubscribed
        do {
            try await self.client.setSubscribed(self.isSubscribed, channelId: self.channelId)
        } catch {
            self.logger.error("Failed to toggle channel subscription: \(error.localizedDescription)")
            self.isSubscribed = wasSubscribed
        }
    }

    // MARK: - Private

    /// Swaps the grid to a new list, keeping the header in place. Stale runs
    /// (an earlier sort or search that resolves late) are discarded.
    ///
    /// The grid and controls move before the request so the new chip or query
    /// reads as active while it loads, and all of it moves back if the request
    /// fails. Leaving the controls moved would make `selectSort` and `runSearch`
    /// treat the failed selection as the current one and refuse to run it
    /// again, so the user could not retry what just failed.
    private func replaceList(
        mode: Mode,
        sortTitle: String?,
        clearingQuery: Bool,
        fetch: @escaping () async throws -> YouTubeFeed
    ) async {
        // Only a swap that wipes the query owes it back on failure.
        let clearedQuery = clearingQuery ? self.searchQuery : nil

        self.listGeneration += 1
        let listRun = self.listGeneration
        self.listError = nil
        self.mode = mode
        if let sortTitle {
            self.selectedSortTitle = sortTitle
        }
        if clearingQuery {
            self.searchQuery = ""
        }
        self.videos = []
        self.continuation = nil
        self.loadingState = .loadingMore

        do {
            let feed = try await fetch()
            guard listRun == self.listGeneration else { return }
            self.videos = feed.videos
            self.continuation = feed.continuation
            self.paginationTrigger += 1
            self.commitList()
            self.loadingState = .loaded
        } catch {
            guard listRun == self.listGeneration else { return }
            // Nothing replaced the list, so put back everything the swap
            // cleared: a failed sort must not cost the user the grid they had.
            self.restoreCommittedList()
            if let clearedQuery {
                self.searchQuery = clearedQuery
            }
            self.loadingState = .loaded
            if error is CancellationError {
                return
            }
            self.logger.error("Failed to load channel videos: \(error.localizedDescription)")
            self.listError = LoadingError(from: error)
        }
    }

    /// Records the list now on screen as the one a failed swap rolls back to.
    private func commitList() {
        self.committed = ListSnapshot(
            mode: self.mode,
            sortTitle: self.selectedSortTitle,
            videos: self.videos,
            continuation: self.continuation
        )
    }

    /// Restores the list only. What the user has typed is theirs, not part of
    /// the committed list, so a failed search leaves the query in the field to
    /// be submitted again.
    private func restoreCommittedList() {
        self.mode = self.committed.mode
        self.selectedSortTitle = self.committed.sortTitle
        self.videos = self.committed.videos
        self.continuation = self.committed.continuation
    }

    private func append(_ feed: YouTubeFeed) {
        let existing = Set(self.videos.map(\.videoId))
        self.videos.append(contentsOf: feed.videos.filter { !existing.contains($0.videoId) })
        self.continuation = feed.continuation
        self.paginationTrigger += 1
    }
}
