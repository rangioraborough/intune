import AppKit
import Foundation

/// The user's desktop session: wallpaper and default browser. Only usable from the session agent
/// (it needs the user's window server connection); faked in tests.
public protocol Desktop: Sendable {
    func wallpaper() -> URL?
    /// Set the picture on every screen.
    func setWallpaper(_ url: URL) throws
    /// App that opens http links now.
    func defaultBrowser() -> URL?
    /// Ask macOS to make `app` the browser. macOS shows the user a confirmation dialog.
    func requestDefaultBrowser(_ app: URL) -> BrowserAnswer
}

public enum BrowserAnswer: Sendable {
    case agreed
    case declined
    /// Nobody answered in time (e.g. no one at the Mac). Ask again next time.
    case noAnswer
}

public struct LiveDesktop: Desktop {
    public init() {}

    public func wallpaper() -> URL? {
        onMain { NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } }
    }

    public func setWallpaper(_ url: URL) throws {
        try onMain {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        }
    }

    public func defaultBrowser() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://example.com")!)
    }

    public func requestDefaultBrowser(_ app: URL) -> BrowserAnswer {
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in done.signal() }
        // The user has to answer the system dialog. Don't hold the session run up for long.
        if done.wait(timeout: .now() + 120) == .timedOut { return .noAnswer }
        return defaultBrowser()?.standardizedFileURL == app.standardizedFileURL ? .agreed : .declined
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
