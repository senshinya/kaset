import Foundation
import Testing
import WebKit
@testable import Kaset

// MARK: - WebPlaybackReplacementNavigationTests

@Suite("Web playback replacement navigation", .serialized, .tags(.service))
@MainActor
struct WebPlaybackReplacementNavigationTests {
    @Test("Failed location replacement reports a trackable navigation", .timeLimit(.minutes(1)))
    func failedLocationReplacementReportsTrackableNavigation() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            FailingURLSchemeHandler(),
            forURLScheme: "kaset-test"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let probe = ReplacementNavigationProbe()

        try await probe.loadInitialDocument(in: webView)

        let generation: UInt64 = 42
        let destination = try #require(URL(
            string: "kaset-test://playback/watch?v=replacement&kasetDocumentGeneration=\(generation)"
        ))
        let observation = try await probe.replaceLocation(
            in: webView,
            with: WebPlaybackDocumentGeneration.locationReplacementScript(for: destination)
        )

        #expect(
            WebPlaybackDocumentGeneration.generation(from: observation.provisionalURL)
                == generation
        )
        #expect(observation.startedNavigationID == observation.failedNavigationID)
    }
}

// MARK: - FailingURLSchemeHandler

private final class FailingURLSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        urlSchemeTask.didFailWithError(URLError(.cannotConnectToHost))
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}

// MARK: - ReplacementNavigationProbe

@MainActor
private final class ReplacementNavigationProbe: NSObject, WKNavigationDelegate {
    struct Observation {
        let provisionalURL: URL?
        let startedNavigationID: ObjectIdentifier?
        let failedNavigationID: ObjectIdentifier?
    }

    private struct ContentProcessTerminatedError: Error {}

    private var initialLoadContinuation: CheckedContinuation<Void, any Error>?
    private var replacementContinuation: CheckedContinuation<Observation, any Error>?
    private var provisionalURL: URL?
    private var startedNavigationID: ObjectIdentifier?

    func loadInitialDocument(in webView: WKWebView) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.initialLoadContinuation = continuation
                webView.navigationDelegate = self
                webView.loadHTMLString(
                    "<html><body></body></html>",
                    baseURL: URL(string: "https://music.youtube.com/watch?v=initial")
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.finishInitialLoad(throwing: CancellationError())
            }
        }
    }

    func replaceLocation(in webView: WKWebView, with script: String) async throws -> Observation {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.replacementContinuation = continuation
                webView.evaluateJavaScript(script) { _, error in
                    if let error {
                        self.finishReplacement(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finishReplacement(throwing: CancellationError())
            }
        }
    }

    private func finishInitialLoad(throwing error: (any Error)? = nil) {
        guard let continuation = self.initialLoadContinuation else { return }
        self.initialLoadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func finishReplacement(
        failedNavigation: WKNavigation? = nil,
        throwing error: (any Error)? = nil
    ) {
        guard let continuation = self.replacementContinuation else { return }
        self.replacementContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: Observation(
                provisionalURL: self.provisionalURL,
                startedNavigationID: self.startedNavigationID,
                failedNavigationID: failedNavigation.map(ObjectIdentifier.init)
            ))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.replacementContinuation != nil else { return }
        self.provisionalURL = webView.url
        self.startedNavigationID = navigation.map(ObjectIdentifier.init)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        if self.initialLoadContinuation != nil {
            self.finishInitialLoad()
        }
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError _: any Error) {
        self.finishReplacement(failedNavigation: navigation)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError _: any Error
    ) {
        self.finishReplacement(failedNavigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        let error = ContentProcessTerminatedError()
        self.finishInitialLoad(throwing: error)
        self.finishReplacement(throwing: error)
    }
}
