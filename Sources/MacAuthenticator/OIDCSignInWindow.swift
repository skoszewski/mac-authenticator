import AppKit
import Vault
import WebKit

/// One OIDC sign-in, in a window of the app: a web view loads the identity provider's pages, and
/// the redirect to the callback address ends the sign-in without being loaded, so nothing listens.
@MainActor
final class OIDCSignInWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// The persistent store that keeps the identity provider's cookies, apart from Safari's.
    private static let storeID = UUID(uuidString: "6F0D3C1E-5A47-4C0B-9B7E-2D8A41C6E0A5")!

    private var policy: OIDCSignInPolicy?
    private var window: NSWindow?
    private var webView: WKWebView?
    private let hostLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var continuation: CheckedContinuation<OIDCCallback, Error>?
    private var timeout: Task<Void, Never>?

    /// Opens the window on the authorisation URL and returns what the identity provider sent to the
    /// redirect URI; closing the window throws a `CancellationError`.
    func run(url: URL, redirect: URL, title: String) async throws -> OIDCCallback {
        policy = OIDCSignInPolicy(redirect: redirect)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            show(url: url, title: title)
        }
    }

    /// Closes the window and ends the sign-in as cancelled.
    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func show(url: URL, title: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        hostLabel.font = .systemFont(ofSize: 13, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let lock = NSImageView()
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure connection")
        let header = NSStackView(views: [lock, hostLabel])
        let top = NSStackView(views: [header, errorLabel])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 4

        let content = NSView()
        for view in [top, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            webView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.center()
        self.window = window

        timeout = Task {
            try? await Task.sleep(for: .seconds(300))
            finish(.failure(VaultError.oidc("The sign-in did not finish in time.")))
        }
        webView.load(URLRequest(url: url))
        Dialogs.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Ends the sign-in once: closes the window and resumes the caller with the result.
    private func finish(_ result: Result<OIDCCallback, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        timeout?.cancel()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        continuation.resume(with: result)
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
    }

    private func showHost() {
        hostLabel.stringValue = webView?.url?.host ?? ""
    }

    func windowWillClose(_ notification: Notification) {
        finish(.failure(CancellationError()))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch policy?.decide(navigationAction.request.url) ?? .block("No sign-in is running.") {
        case let .callback(callback):
            finish(.success(callback))
            return .cancel
        case .allow:
            errorLabel.isHidden = true
            return .allow
        case let .block(reason):
            showError(reason)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        showHost()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        showHost()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        show(error)
    }

    /// Shows what went wrong with a load, in words; a navigation the policy cancelled is not one.
    private func show(_ error: Error) {
        let code = (error as NSError).code
        if (error as? URLError)?.code == .cancelled || (error as NSError).domain == "WebKitErrorDomain" && code == 102 {
            return
        }
        let problem = VaultProblem(error)
        showError("\(problem.title). \(problem.suggestion)")
    }

    /// A page that opens a window, such as a provider's multi-factor step, loads in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    /// Shows a message of a page as a sheet naming the page's host, and returns the button chosen.
    private func present(_ message: String, from frame: WKFrameInfo, buttons: [String]) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "The page"
        alert.informativeText = message
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        guard let window else {
            return alert.runModal()
        }
        return await alert.beginSheetModal(for: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await present(message, from: frame, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await present(message, from: frame, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        nil
    }
}
