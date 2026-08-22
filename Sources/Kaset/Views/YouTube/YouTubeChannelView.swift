import SwiftUI

// MARK: - YouTubeChannelView

/// A YouTube channel page: header, subscribe control, and the channel's
/// Videos tab with sorting, in-channel search, and paged loading.
struct YouTubeChannelView: View {
    @Environment(AuthService.self) private var authService
    @State private var viewModel: YouTubeChannelViewModel
    @FocusState private var isSearchFieldFocused: Bool

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    private static let brandAccent = PackageResourceLookup.brandAccent

    init(channelId: String, client: any YouTubeClientProtocol) {
        self._viewModel = State(
            initialValue: YouTubeChannelViewModel(channelId: channelId, client: client)
        )
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            case .loaded, .loadingMore:
                if let detail = self.viewModel.detail {
                    self.content(for: detail)
                }
            }
        }
        .navigationTitle(Text(self.viewModel.detail?.channel.name ?? ""))
        .task {
            await self.viewModel.load()
        }
    }

    private func content(for detail: YouTubeChannelDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.header(for: detail.channel)

                self.controls

                if let listError = self.viewModel.listError {
                    self.listErrorBanner(listError)
                }

                self.videoGrid
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so content extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }

    // MARK: - Header

    private func header(for channel: YouTubeChannel) -> some View {
        HStack(spacing: 16) {
            CachedAsyncImage(
                url: channel.thumbnailURL,
                targetSize: CGSize(width: 80, height: 80)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 80, height: 80)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.title.bold())
                    .lineLimit(1)

                let meta = [channel.handle, channel.subscriberCountText].compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let description = channel.descriptionSnippet, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if self.authService.hasPersonalAccount, self.viewModel.canSubscribe {
                self.subscribeButton
            }
        }
    }

    private var subscribeButton: some View {
        Button {
            Task {
                await self.viewModel.toggleSubscribed()
            }
        } label: {
            Text(
                self.viewModel.isSubscribed
                    ? String(localized: "Subscribed")
                    : String(localized: "Subscribe")
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(self.viewModel.isSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .compatGlass(
                interactive: true,
                tint: self.viewModel.isSubscribed ? nil : Self.brandAccent,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(self.viewModel.isUpdatingSubscription)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.channelSubscribeButton)
    }

    /// A failed sort or search, shown in place rather than as a full-page
    /// error: the previous list is still valid, and the control that failed is
    /// still on screen to try again.
    private func listErrorBanner(_ error: LoadingError) -> some View {
        Label(error.message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.channelListError)
    }

    // MARK: - Sorting & Search

    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            if !self.viewModel.sortOptions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(self.viewModel.sortOptions) { option in
                        self.sortChip(option)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.channelSortChips)
            }

            Spacer(minLength: 12)

            self.searchField
        }
    }

    private func sortChip(_ option: YouTubeChannelSortOption) -> some View {
        // A chip is only "on" while the Videos tab is showing: search results
        // are not in any of these orders.
        let isActive = !self.viewModel.isSearching
            && self.viewModel.selectedSortTitle == option.title

        return Button {
            Task {
                await self.viewModel.selectSort(option)
            }
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(option.title)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Search this channel"),
                text: self.$viewModel.searchQuery
            )
            .textFieldStyle(.plain)
            .focused(self.$isSearchFieldFocused)
            .onSubmit {
                Task {
                    await self.viewModel.runSearch()
                }
            }
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.channelSearchField)

            // Also while results are showing: emptying the field by hand does
            // not drop them, so the way back to the Videos tab has to stay put.
            if !self.viewModel.searchQuery.isEmpty || self.viewModel.isSearching {
                Button {
                    Task {
                        await self.viewModel.clearSearch()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 260)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: - Grid

    @ViewBuilder
    private var videoGrid: some View {
        if self.viewModel.videos.isEmpty {
            if self.viewModel.loadingState == .loadingMore {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ContentUnavailableView {
                    Label(
                        self.viewModel.isSearching
                            ? String(localized: "No matching videos")
                            : String(localized: "No videos"),
                        systemImage: "play.rectangle"
                    )
                }
            }
        } else {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(self.viewModel.videos) { video in
                    NavigationLink(value: YouTubeRoute.watch(video)) {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.interactiveCard)
                }

                if self.viewModel.hasMoreVideos {
                    ProgressView()
                        .controlSize(.small)
                        .task(id: self.viewModel.paginationTrigger) {
                            await self.viewModel.loadMore()
                        }
                }
            }
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let channelSubscribeButton = "youtubeContent.channelSubscribeButton"
    static let channelSortChips = "youtubeContent.channelSortChips"
    static let channelSearchField = "youtubeContent.channelSearchField"
    static let channelListError = "youtubeContent.channelListError"
}
