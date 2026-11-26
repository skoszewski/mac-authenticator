import AppKit
import Observation
import SwiftUI
import TOTP

/// The floating windows showing one account's code, or one secret account's secret, each, at most one
/// per account; the store is told which are open, so it holds the secrets of the OTP accounts alone.
@MainActor
final class CodeWindows {
    private let store: AccountStore
    private var panels: [UUID: NSPanel] = [:]
    private var closeObservers: [UUID: NSObjectProtocol] = [:]
    private var secretModels: [UUID: SecretWindowModel] = [:]
    private var resizeObservers: [UUID: NSObjectProtocol] = [:]

    init(store: AccountStore) {
        self.store = store
    }

    /// Brings the account's window to the front, making it on the first call.
    func show(_ account: Account) {
        if let panel = panels[account.id] {
            store.setWindowOpen(account.id, true)
            panel.orderFrontRegardless()
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        if account.kind == .secret {
            style.insert(.resizable)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 110), styleMask: style,
                            backing: .buffered, defer: false)
        panel.title = account.name
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let id = account.id
        switch account.kind {
        case .otp:
            panel.contentView = NSHostingView(rootView: CodeView(store: store, accountID: id))
        case .secret:
            let model = SecretWindowModel()
            let hosting = NSHostingView(rootView: SecretView(store: store, accountID: id, model: model))
            // The window fits a shown secret, with its top edge in place, unless the user has resized it;
            // hiding the secret does not resize it.
            model.layoutChanged = { [weak panel, weak hosting, weak model] in
                DispatchQueue.main.async {
                    guard let panel, let hosting, model?.userResized == false else {
                        return
                    }
                    hosting.layoutSubtreeIfNeeded()
                    let top = panel.frame.maxY
                    panel.setContentSize(hosting.fittingSize)
                    var frame = panel.frame
                    frame.origin.y = top - frame.height
                    panel.setFrame(frame, display: true)
                }
            }
            secretModels[id] = model
            panel.contentView = hosting
            resizeObservers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
            ) { [weak model] _ in
                MainActor.assumeIsolated {
                    model?.userResized = true
                }
            }
        }
        panel.center()
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.secretModels[id]?.userResized = false
                self?.secretModels[id]?.hide()
                self?.store.setWindowOpen(id, false)
            }
        }
        panels[id] = panel
        store.setWindowOpen(id, true)
        panel.orderFrontRegardless()
    }

    /// Closes and forgets the windows of accounts no longer registered.
    func closeRemoved() {
        let ids = Set(store.accounts.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            if let observer = closeObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = resizeObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(observer)
            }
            panels[id] = nil
            secretModels[id] = nil
        }
    }
}

/// What a secret window shows: the secret while it is revealed, and when it is hidden again. The
/// window is kept when it is closed, so closing hides the secret. A task hides it when its time is
/// over, so the hiding does not depend on the window being redrawn.
@MainActor
@Observable
final class SecretWindowModel {
    private(set) var value: String?
    /// When the secret is hidden again, and the seconds it is shown for; nil and 0 never hide it.
    private(set) var hideAt: Date?
    private(set) var total = 0
    private(set) var busy = false
    /// Whether the secret read was longer than `maxShownLength`, so that it is not shown; it is
    /// copied instead.
    private(set) var tooLong = false
    /// The width the window gets when the secret is shown or hidden and the user has not resized it: the
    /// width of the secret on one line, up to a maximum, the font shrinking when that is not enough.
    private(set) var idealWidth = SecretWindowModel.minWidth
    /// The narrowest the window can be made: the width of the secret on one line in the smallest font.
    private(set) var minimumWidth = SecretWindowModel.floorWidth
    /// Whether the user has resized the window since it was opened; it is then left as it is.
    @ObservationIgnored var userResized = false
    /// Called after the secret is shown, so that the window can fit it; hiding it leaves the window as it is.
    @ObservationIgnored var layoutChanged: (() -> Void)?
    static let minWidth: CGFloat = 240
    static let floorWidth: CGFloat = 200
    static let maxAutoWidth: CGFloat = 520
    /// The secrets longer than this many characters are not shown in a window.
    static let maxShownLength = 64
    static let fontSize: CGFloat = 28
    /// The smallest font the secret is shown in; the window cannot be made narrower than it needs.
    static let smallestFontSize: CGFloat = 12
    private static let padding: CGFloat = 36

    private static func lineWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)])
            .size().width
    }
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        value = nil
        hideAt = nil
        total = 0
        tooLong = false
        idealWidth = Self.minWidth
        minimumWidth = Self.floorWidth
    }

    /// Reads the secret, after the authentication its settings ask for, and shows it for its hide time;
    /// nothing happens when the user cancels, and an error is shown to the user.
    func reveal(_ account: Account, store: AccountStore) async {
        guard value == nil, !busy else {
            return
        }
        busy = true
        defer {
            busy = false
        }
        do {
            guard let secret = try await store.revealSecret(of: account) else {
                return
            }
            guard secret.count <= Self.maxShownLength else {
                tooLong = true
                layoutChanged?()
                return
            }
            value = secret
            idealWidth = min(max(Self.lineWidth(secret, fontSize: Self.fontSize) + Self.padding, Self.minWidth),
                             Self.maxAutoWidth)
            minimumWidth = max(Self.floorWidth, Self.lineWidth(secret, fontSize: Self.smallestFontSize) + Self.padding)
            total = account.settings.hideSeconds
            hideAt = total > 0 ? Date().addingTimeInterval(Double(total)) : nil
            if total > 0 {
                let seconds = total
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    if !Task.isCancelled {
                        self?.hide()
                    }
                }
            }
            layoutChanged?()
        } catch is CancellationError {
        } catch {
            Dialogs.showProblem("The secret was not read", error)
        }
    }
}

/// The content of a secret window: the secret masked, which a click reveals; then the secret, the
/// time left before it is hidden again, and a Copy button; or why the secret cannot be read.
struct SecretView: View {
    let store: AccountStore
    let accountID: UUID
    let model: SecretWindowModel

    private static let valueFont = Font.system(size: SecretWindowModel.fontSize, weight: .medium, design: .monospaced)

    var body: some View {
        if let account = store.accounts.first(where: { $0.id == accountID }) {
            VStack(spacing: 8) {
                if let problem = store.problem(of: account) {
                    Text(problem.title)
                        .bold()
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(problem.suggestion)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let value = model.value {
                    Text(value)
                        .font(Self.valueFont)
                        .lineLimit(1)
                        .minimumScaleFactor(SecretWindowModel.smallestFontSize / SecretWindowModel.fontSize)
                        .textSelection(.enabled)
                    HStack {
                        if let hideAt = model.hideAt, model.total > 0 {
                            let left = max(0, Int(hideAt.timeIntervalSince(store.now).rounded(.up)))
                            ProgressView(value: Double(left), total: Double(model.total))
                            Text("\(left)s")
                                .monospacedDigit()
                                .frame(width: 32, alignment: .trailing)
                        } else {
                            Spacer()
                            Button("Hide") {
                                model.hide()
                            }
                        }
                        Button("Copy") {
                            Task {
                                do {
                                    try await store.copySecret(of: account)
                                } catch is CancellationError {
                                } catch {
                                    Dialogs.showProblem("The secret was not copied", error)
                                }
                            }
                        }
                    }
                } else if model.tooLong {
                    Text("The secret is longer than \(SecretWindowModel.maxShownLength) characters, so it is not shown.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy") {
                        Task {
                            do {
                                try await store.copySecret(of: account)
                            } catch is CancellationError {
                            } catch {
                                Dialogs.showProblem("The secret was not copied", error)
                            }
                        }
                    }
                } else {
                    Text("********")
                        .font(Self.valueFont)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                await model.reveal(account, store: store)
                            }
                        }
                    Text(model.busy ? "Reading the secret..." : "Click to show")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(minWidth: model.minimumWidth, idealWidth: model.idealWidth, maxWidth: .infinity,
                   minHeight: 90, maxHeight: .infinity)
        }
    }
}

/// The content of a code window: the code, the time left of it, and a Copy button; or why the
/// secret could not be read. A Vault code that is not fetched yet is empty, with a dot in the
/// corner.
struct CodeView: View {
    let store: AccountStore
    let accountID: UUID

    var body: some View {
        let now = store.now
        if let account = store.accounts.first(where: { $0.id == accountID }) {
            let code = store.code(of: account)
            let problem = store.problem(of: account)
            // A Vault code not yet fetched keeps the layout of a shown code, with an empty code.
            let waiting = code == nil && store.vaultKeys[accountID] != nil && problem == nil
                && store.secretErrors[accountID] == nil
            VStack(spacing: 8) {
                if code != nil || waiting {
                    Text(code?.groupedCode ?? " ")
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        ProgressView(value: Double(account.secondsLeft(at: now)), total: Double(account.period))
                        Text("\(account.secondsLeft(at: now))s")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                        Button("Copy") {
                            Task {
                                do {
                                    try await store.copyCode(of: account)
                                } catch {
                                    Dialogs.showProblem("The code was not copied", error)
                                }
                            }
                        }
                    }
                } else if let problem {
                    Text(problem.title)
                        .bold()
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(problem.suggestion)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(store.secretErrors[accountID] ?? "The secret is not read.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 240)
            .overlay(alignment: .bottomTrailing) {
                // The dot shows that the code is being fetched from Vault.
                if waiting {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .padding(4)
                }
            }
        }
    }
}
