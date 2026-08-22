import Foundation
import Testing
@testable import Kaset

// MARK: - ChannelPageParserTests

@Suite("ChannelPageParser", .tags(.parser))
struct ChannelPageParserTests {
    @Test("Parses channel metadata and landing videos from a captured browse response")
    func parsesChannelPage() throws {
        let data = try loadYouTubeFixture("youtube_channel")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        #expect(detail.channel.channelId == "UC_x5XG1OV2P6uZZ5FSM9Ttw")
        #expect(detail.channel.name == "Google for Developers")
        #expect(detail.channel.thumbnailURL != nil)
        #expect(detail.channel.descriptionSnippet?.isEmpty == false)
        #expect(!detail.videos.isEmpty)
    }

    @Test("Videos tab yields a paging token so the full catalog is reachable")
    func parsesVideosTabContinuation() throws {
        let data = try loadYouTubeFixture("youtube_channel_videos")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        #expect(detail.channel.name == "Google for Developers")
        #expect(detail.channel.subscriberCountText?.contains("subscribers") == true)
        #expect(!detail.videos.isEmpty)
        #expect(detail.videosContinuation?.isEmpty == false)
    }

    @Test("Videos tab exposes its sort chips with replayable tokens")
    func parsesSortChips() throws {
        let data = try loadYouTubeFixture("youtube_channel_videos")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        #expect(detail.sortOptions.map(\.title) == ["Latest", "Popular", "Oldest"])
        #expect(detail.sortOptions.allSatisfy { !$0.continuation.isEmpty })
        #expect(detail.sortOptions.filter(\.isSelected).map(\.title) == ["Latest"])
    }

    @Test("Search tab params are read from the response, not a localized tab title")
    func parsesSearchParams() throws {
        let data = try loadYouTubeFixture("youtube_channel_videos")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        // The captured page lists channel-specific tabs (Live, Courses) around
        // the standard ones, so the match has to key off the tab name encoded
        // in the params rather than the rendered title.
        #expect(detail.searchParams == ChannelPageParser.searchTabParams)
    }

    @Test("Tab params decode to their untranslated tab name")
    func decodesTabNameFromParams() {
        #expect(ChannelPageParser.tabName(fromParams: ChannelPageParser.videosTabParams) == "videos")
        #expect(ChannelPageParser.tabName(fromParams: ChannelPageParser.searchTabParams) == "search")
        #expect(ChannelPageParser.tabName(fromParams: "not-base64!") == nil)
    }

    @Test("A signed-out page reports no subscribe state")
    func signedOutPageHasNoSubscribeState() throws {
        let data = try loadYouTubeFixture("youtube_channel_videos")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        #expect(detail.isSubscribed == nil)
    }

    @Test("Reads subscribe state from an inline subscribeButtonViewModel")
    func readsInlineSubscribeState() {
        let data: [String: Any] = [
            "header": ["pageHeaderRenderer": ["content": ["pageHeaderViewModel": [
                "actions": ["flexibleActionsViewModel": ["actionsRows": [
                    ["actions": [["subscribeButtonViewModel": ["subscribed": true]]]],
                ]]],
            ]]]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == true)
    }

    @Test(
        "Reads subscribe state from the entity the button points at",
        arguments: ["subscribedEntityKey", "stateEntityStoreKeyId"]
    )
    func readsEntityStoreSubscribeState(keyField: String) {
        let data: [String: Any] = [
            "header": ["pageHeaderRenderer": [
                "subscribeButtonViewModel": [keyField: "wanted-key"],
            ]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": [
                ["payload": ["subscriptionStateEntity": ["key": "other-key", "subscribed": true]]],
                ["payload": ["subscriptionStateEntity": ["key": "wanted-key", "subscribed": false]]],
            ]]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == false)
    }

    @Test("A keyed button never falls back to another channel's entity")
    func keyedButtonIgnoresUnrelatedEntity() {
        let data: [String: Any] = [
            "header": ["pageHeaderRenderer": [
                "subscribeButtonViewModel": ["stateEntityStoreKeyId": "this-channel"],
            ]],
            // Only a recommended channel's entity came back; adopting it would
            // show the wrong state and send the inverse action.
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": [
                ["payload": ["subscriptionStateEntity": ["key": "other-channel", "subscribed": true]]],
            ]]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == nil)
    }

    @Test("A recommended channel's subscribe button outside the header is ignored")
    func ignoresSubscribeButtonsOutsideTheHeader() {
        let data: [String: Any] = [
            "header": ["pageHeaderRenderer": ["content": ["pageHeaderViewModel": [:]]]],
            // Channel pages carry these for recommended-channel shelves.
            "contents": ["gridChannelRenderer": [
                "subscribeButton": ["subscribeButtonRenderer": ["subscribed": true]],
            ]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == nil)
    }

    @Test("No header subscribe button means no state, even with a lone entity")
    func headerlessPageIgnoresLoneEntity() {
        let data: [String: Any] = [
            // Signed out: the header offers a sign-in button, not a subscribe
            // toggle, so the only entity present belongs to something else.
            "header": ["pageHeaderRenderer": ["content": ["pageHeaderViewModel": [
                "actions": ["flexibleActionsViewModel": ["actionsRows": [
                    ["actions": [["buttonViewModel": ["title": "Subscribe"]]]],
                ]]],
            ]]]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": [
                ["payload": ["subscriptionStateEntity": ["key": "other-channel", "subscribed": true]]],
            ]]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == nil)
    }

    @Test("Refuses to guess when several unkeyed subscription entities are present")
    func ambiguousEntityStoreYieldsNoState() {
        let data: [String: Any] = [
            "header": ["pageHeaderRenderer": ["subscribeButtonViewModel": [:]]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": [
                ["payload": ["subscriptionStateEntity": ["subscribed": true]]],
                ["payload": ["subscriptionStateEntity": ["subscribed": false]]],
            ]]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == nil)
    }

    @Test("Still reads the legacy subscribeButtonRenderer shape")
    func readsLegacySubscribeState() {
        let data: [String: Any] = [
            "header": ["c4TabbedHeaderRenderer": [
                "subscribeButton": ["subscribeButtonRenderer": ["subscribed": true]],
            ]],
        ]

        #expect(ChannelPageParser.isSubscribed(in: data) == true)
    }
}
