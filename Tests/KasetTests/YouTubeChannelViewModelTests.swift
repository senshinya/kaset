import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeChannelViewModelTests

@Suite("YouTubeChannelViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeChannelViewModelTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeChannelViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeChannelViewModel(channelId: "UC-test", client: self.mockClient)
    }

    // MARK: - Loading

    @Test("Load surfaces the Videos tab, its sort chips, and its paging token")
    func loadPopulatesVideosTab() async {
        self.mockClient.channelDetail = Self.makeDetail()

        await self.sut.load()

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.count == 3)
        #expect(self.sut.sortOptions.map(\.title) == ["Latest", "Popular", "Oldest"])
        #expect(self.sut.selectedSortTitle == "Latest")
        #expect(self.sut.hasMoreVideos)
    }

    @Test("Paging appends the next page and drops repeats")
    func loadMoreAppendsWithoutDuplicates() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        // The second page repeats video-0 and adds two more.
        self.mockClient.feedContinuation = YouTubeFeed(
            videos: [
                MockYouTubeClient.makeVideo(videoId: "video-0", title: "Video 0"),
                MockYouTubeClient.makeVideo(videoId: "video-3", title: "Video 3"),
                MockYouTubeClient.makeVideo(videoId: "video-4", title: "Video 4"),
            ],
            continuation: nil
        )

        await self.sut.loadMore()

        #expect(self.mockClient.lastFeedContinuation == "page-2")
        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1", "video-2", "video-3", "video-4"])
        #expect(!self.sut.hasMoreVideos)
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("A paging token dropped after a failure is not resurrected by a rollback")
    func droppedPagingTokenStaysDropped() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        #expect(self.sut.hasMoreVideos)

        self.mockClient.error = YTMusicError.parseError(message: "offline")
        await self.sut.loadMore()
        #expect(!self.sut.hasMoreVideos)

        // The sort fails too and rolls back; the dead page must stay gone.
        await self.sut.selectSort(Self.sortOption(title: "Popular", token: "sort-popular"))

        #expect(!self.sut.hasMoreVideos)
    }

    // MARK: - Sorting

    @Test("Selecting a sort chip replays that chip's token and replaces the list")
    func selectSortReplaysChipToken() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.mockClient.feedContinuation = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "popular-0", title: "Popular 0")],
            continuation: "popular-page-2"
        )

        await self.sut.selectSort(Self.sortOption(title: "Popular", token: "sort-popular"))

        #expect(self.mockClient.lastFeedContinuation == "sort-popular")
        #expect(self.sut.selectedSortTitle == "Popular")
        #expect(self.sut.videos.map(\.videoId) == ["popular-0"])
        #expect(self.sut.hasMoreVideos)
        #expect(self.sut.loadingState == .loaded)
    }

    @Test("Re-tapping the active sort chip does not refetch")
    func reselectingActiveSortIsANoOp() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()

        await self.sut.selectSort(Self.sortOption(title: "Latest", token: "sort-latest"))

        #expect(self.mockClient.lastFeedContinuation == nil)
    }

    @Test("A sort started during a reload wins over the reload's default list")
    func sortDuringReloadIsNotUndone() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()

        let channelGate = AsyncGate()
        self.mockClient.channelGate = channelGate
        let reload = Task { await self.sut.load() }
        await self.waitForPageLoad()

        self.mockClient.feedContinuation = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "popular-0", title: "Popular 0")],
            continuation: nil
        )
        await self.sut.selectSort(Self.sortOption(title: "Popular", token: "sort-popular"))
        #expect(self.sut.videos.map(\.videoId) == ["popular-0"])

        await channelGate.open()
        await reload.value

        #expect(self.sut.videos.map(\.videoId) == ["popular-0"])
        #expect(self.sut.selectedSortTitle == "Popular")
    }

    @Test("A stale reload failure does not replace newer sort results")
    func staleReloadFailureDoesNotReplaceNewerList() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()

        let channelGate = AsyncGate()
        self.mockClient.channelGate = channelGate
        let reload = Task { await self.sut.load() }
        await self.waitForPageLoad()

        self.mockClient.feedContinuation = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "popular-0", title: "Popular 0")],
            continuation: nil
        )
        await self.sut.selectSort(Self.sortOption(title: "Popular", token: "sort-popular"))

        // The older reload now fails; its error must not take the screen.
        self.mockClient.error = YTMusicError.parseError(message: "offline")
        await channelGate.open()
        await reload.value

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.map(\.videoId) == ["popular-0"])
    }

    @Test("The same sort chip can be retried after a failure")
    func failedSortCanBeRetried() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        let popular = Self.sortOption(title: "Popular", token: "sort-popular")
        self.mockClient.error = YTMusicError.parseError(message: "offline")

        await self.sut.selectSort(popular)
        // The chip that failed must not read as the current order, or its guard
        // would swallow the retry, and the grid it was replacing survives
        // alongside an in-place error rather than a full-page one.
        #expect(self.sut.selectedSortTitle == "Latest")
        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1", "video-2"])
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.listError != nil)

        self.mockClient.error = nil
        self.mockClient.feedContinuation = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "popular-0", title: "Popular 0")],
            continuation: nil
        )
        await self.sut.selectSort(popular)

        #expect(self.sut.selectedSortTitle == "Popular")
        #expect(self.sut.videos.map(\.videoId) == ["popular-0"])
        #expect(self.sut.listError == nil)
    }

    @Test("A cancelled sort leaves the grid it was replacing in place")
    func cancelledSortKeepsPreviousList() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.mockClient.error = CancellationError()

        await self.sut.selectSort(Self.sortOption(title: "Popular", token: "sort-popular"))

        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1", "video-2"])
        #expect(self.sut.hasMoreVideos)
        #expect(self.sut.selectedSortTitle == "Latest")
    }

    // MARK: - In-Channel Search

    @Test("Search forwards the channel's own search params")
    func searchUsesChannelSearchParams() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.mockClient.channelSearchFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "hit-0", title: "Hit 0")],
            continuation: nil
        )
        self.sut.searchQuery = "  black hole  "

        await self.sut.runSearch()

        #expect(
            self.mockClient.channelSearchCalls == [
                MockYouTubeClient.ChannelSearchCall(
                    channelId: "UC-test",
                    query: "black hole",
                    params: "search-params"
                ),
            ]
        )
        #expect(self.sut.isSearching)
        #expect(self.sut.videos.map(\.videoId) == ["hit-0"])
    }

    @Test("A blank query never reaches the client")
    func blankQuerySkipsSearch() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.sut.searchQuery = "   "

        await self.sut.runSearch()

        #expect(self.mockClient.channelSearchCalls.isEmpty)
        #expect(!self.sut.isSearching)
    }

    @Test("Clearing a search restores the Videos tab in the active order")
    func clearSearchRestoresSortedVideos() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.mockClient.channelSearchFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "hit-0", title: "Hit 0")],
            continuation: nil
        )
        self.sut.searchQuery = "black hole"
        await self.sut.runSearch()

        self.mockClient.feedContinuation = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: nil
        )
        await self.sut.clearSearch()

        #expect(!self.sut.isSearching)
        #expect(self.sut.searchQuery.isEmpty)
        #expect(self.mockClient.lastFeedContinuation == "sort-latest")
        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1"])
    }

    @Test("Reloading the page leaves the search field consistent with the grid")
    func reloadClearsSearchState() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.mockClient.channelSearchFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "hit-0", title: "Hit 0")],
            continuation: nil
        )
        self.sut.searchQuery = "black hole"
        await self.sut.runSearch()
        #expect(self.sut.isSearching)

        // A .task restart or an error retry reloads the unfiltered Videos tab.
        await self.sut.load()

        #expect(!self.sut.isSearching)
        #expect(self.sut.searchQuery.isEmpty)
        #expect(self.sut.videos.count == 3)
    }

    @Test("The same query can be resubmitted after a failed search")
    func failedSearchCanBeRetried() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()
        self.sut.searchQuery = "black hole"
        self.mockClient.error = YTMusicError.parseError(message: "offline")

        await self.sut.runSearch()
        #expect(!self.sut.isSearching)
        #expect(self.sut.searchQuery == "black hole")
        #expect(self.sut.loadingState == .loaded)
        #expect(self.sut.listError != nil)

        self.mockClient.error = nil
        self.mockClient.channelSearchFeed = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "hit-0", title: "Hit 0")],
            continuation: nil
        )
        await self.sut.runSearch()

        #expect(self.sut.isSearching)
        #expect(self.sut.videos.map(\.videoId) == ["hit-0"])
        #expect(self.mockClient.channelSearchCalls.count == 2)
    }

    @Test("A superseded swap cannot roll a later failure back to its empty grid")
    func overlappingSwapsRollBackToTheLastRealList() async {
        self.mockClient.channelDetail = Self.makeDetail()
        await self.sut.load()

        // "Popular" is still in flight when "Oldest" starts, so the live grid
        // is transiently empty; the rollback must ignore that and use the last
        // list the user actually saw.
        let feedGate = AsyncGate()
        self.mockClient.feedGate = feedGate
        let popular = Task {
            await self.sut.selectSort(Self.sortOption(title: "Popular", token: "sort-popular"))
        }
        await self.waitForListSwap()

        self.mockClient.error = CancellationError()
        await self.sut.selectSort(Self.sortOption(title: "Oldest", token: "sort-oldest"))

        await feedGate.open()
        await popular.value

        #expect(self.sut.videos.map(\.videoId) == ["video-0", "video-1", "video-2"])
        #expect(self.sut.selectedSortTitle == "Latest")
        #expect(self.sut.hasMoreVideos)
    }

    // MARK: - Subscription

    @Test("Subscribe toggles optimistically and reports the change to the client")
    func toggleSubscribeSendsChange() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: false)
        await self.sut.load()

        #expect(self.sut.canSubscribe)
        await self.sut.toggleSubscribed()

        #expect(self.sut.isSubscribed)
        #expect(self.mockClient.subscriptionChanges.map(\.channelId) == ["UC-test"])
        #expect(self.mockClient.subscriptionChanges.map(\.subscribed) == [true])
    }

    @Test("A failed subscribe rolls the button back")
    func failedSubscribeRollsBack() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: true)
        await self.sut.load()
        self.mockClient.error = YTMusicError.parseError(message: "offline")

        await self.sut.toggleSubscribed()

        #expect(self.sut.isSubscribed)
    }

    @Test("A second tap while a subscribe request is in flight is ignored")
    func overlappingSubscribeTapsAreSerialized() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: false)
        await self.sut.load()
        let gate = AsyncGate()
        self.mockClient.subscriptionGate = gate

        let first = Task { await self.sut.toggleSubscribed() }
        await self.waitForSubscriptionRequest()

        // The rollback in a second, overlapping call would capture the
        // already-toggled value and could restore a state the server never had.
        await self.sut.toggleSubscribed()
        #expect(self.mockClient.subscriptionChanges.count == 1)

        await gate.open()
        await first.value

        #expect(self.sut.isSubscribed)
        #expect(!self.sut.isUpdatingSubscription)
        #expect(self.mockClient.subscriptionChanges.map(\.subscribed) == [true])
    }

    @Test("A reload landing mid-toggle does not clobber the pending state")
    func reloadDuringSubscribeKeepsPendingState() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: false)
        await self.sut.load()
        let gate = AsyncGate()
        self.mockClient.subscriptionGate = gate
        let toggle = Task { await self.sut.toggleSubscribed() }
        await self.waitForSubscriptionRequest()

        // SwiftUI restarts .task during layout churn, and the page is still
        // cached from before the mutation, so it reports the old state.
        await self.sut.load()
        #expect(self.sut.isSubscribed)

        await gate.open()
        await toggle.value

        #expect(self.sut.isSubscribed)
    }

    @Test("A page load that started before a toggle cannot revert it")
    func staleReloadDoesNotRevertCompletedSubscribe() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: false)
        await self.sut.load()

        // A reload is already in flight, carrying pre-toggle state.
        let channelGate = AsyncGate()
        self.mockClient.channelGate = channelGate
        let reload = Task { await self.sut.load() }
        await self.waitForPageLoad()

        await self.sut.toggleSubscribed()
        #expect(self.sut.isSubscribed)

        await channelGate.open()
        await reload.value

        #expect(self.sut.isSubscribed)
    }

    @Test("A page load that started during a toggle cannot revert it")
    func reloadStartedDuringSubscribeDoesNotRevert() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: false)
        await self.sut.load()

        let subscribeGate = AsyncGate()
        self.mockClient.subscriptionGate = subscribeGate
        let toggle = Task { await self.sut.toggleSubscribed() }
        await self.waitForSubscriptionRequest()

        // The reload starts inside the mutation window but only answers after
        // it, still carrying the page as it looked before the toggle.
        let channelGate = AsyncGate()
        self.mockClient.channelGate = channelGate
        let reload = Task { await self.sut.load() }
        await self.waitForPageLoad()

        await subscribeGate.open()
        await toggle.value
        #expect(self.sut.isSubscribed)

        await channelGate.open()
        await reload.value

        #expect(self.sut.isSubscribed)
    }

    @Test("A page without subscribe state hides the control")
    func missingSubscribeStateHidesControl() async {
        self.mockClient.channelDetail = Self.makeDetail(isSubscribed: nil)
        await self.sut.load()

        #expect(!self.sut.canSubscribe)
        await self.sut.toggleSubscribed()

        #expect(self.mockClient.subscriptionChanges.isEmpty)
    }

    // MARK: - Helpers

    /// Waits for the in-flight list swap to reach the mock's gate.
    private func waitForListSwap() async {
        var spins = 0
        while self.sut.loadingState != .loadingMore, spins < 1000 {
            spins += 1
            await Task.yield()
        }
        #expect(self.sut.loadingState == .loadingMore)
    }

    /// Waits for the in-flight page load to reach the mock's gate.
    private func waitForPageLoad() async {
        var spins = 0
        while self.sut.loadingState != .loading, spins < 1000 {
            spins += 1
            await Task.yield()
        }
        #expect(self.sut.loadingState == .loading)
    }

    /// Waits for the in-flight subscribe request to reach the mock's gate.
    private func waitForSubscriptionRequest() async {
        var spins = 0
        while !self.sut.isUpdatingSubscription, spins < 1000 {
            spins += 1
            await Task.yield()
        }
        #expect(self.sut.isUpdatingSubscription)
    }

    private static func makeDetail(isSubscribed: Bool? = false) -> YouTubeChannelDetail {
        YouTubeChannelDetail(
            channel: YouTubeChannel(channelId: "UC-test", name: "Test Channel"),
            videos: MockYouTubeClient.makeVideos(count: 3),
            videosContinuation: "page-2",
            sortOptions: [
                self.sortOption(title: "Latest", token: "sort-latest", isSelected: true),
                self.sortOption(title: "Popular", token: "sort-popular"),
                self.sortOption(title: "Oldest", token: "sort-oldest"),
            ],
            searchParams: "search-params",
            isSubscribed: isSubscribed
        )
    }

    private static func sortOption(
        title: String,
        token: String,
        isSelected: Bool = false
    ) -> YouTubeChannelSortOption {
        YouTubeChannelSortOption(title: title, continuation: token, isSelected: isSelected)
    }
}
