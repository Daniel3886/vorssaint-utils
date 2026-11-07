// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import UniformTypeIdentifiers

/// `sharingServices(forItems:)` is deprecated without a replacement that lists
/// services. Calling it through this requirement keeps the build free of
/// deprecation warnings while still reading what the Share menu offers.
private protocol NotchSharingServiceLookup {
    static func sharingServices(forItems items: [Any]) -> [NSSharingService]
}
extension NSSharingService: NotchSharingServiceLookup {}

/// Sends files dropped on the island's send zone to one app or service the
/// user chose: AirDrop, a share extension such as Blip or LocalSend, any app
/// that opens files, or the system share menu.
final class NotchSendService: NSObject, NSSharingServiceDelegate {
    static let shared = NotchSendService()

    struct Option: Identifiable, Hashable {
        let target: NotchSendTarget
        let title: String
        let image: NSImage?
        var id: String { target.stored }
    }

    private let presenter = ShelfSharePresenter()
    /// The service performing a send, kept until it reports back.
    private var active: NSSharingService?
    private var displayCache: [String: Option] = [:]

    private override init() {}

    var target: NotchSendTarget {
        NotchSendTarget(stored: UserDefaults.standard.string(forKey: DefaultsKey.notchSendTarget)
                        ?? NotchSendTarget.defaultValue.stored)
    }

    var offersSendDrop: Bool {
        target != .off && NotchSupport.showsFiles() && AppFeature.shelf.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.shelfEnabled)
    }

    /// The dragged files, when the whole drag is files that already exist.
    /// Downloads still arriving and mixed drags stay with the shelf.
    func dropContent(for pasteboard: NSPasteboard) -> [URL]? {
        guard offersSendDrop,
              !pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) else { return nil }
        let urls = ShelfService.shared.fileURLs(from: pasteboard)
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL),
              urls.count >= (pasteboard.pasteboardItems?.count ?? 0) else { return nil }
        return urls
    }

    // MARK: - Sending

    /// Returns true when the share menu opened from `view` and will report
    /// through `menuOpen`; every other target opens its own window.
    @discardableResult
    func send(_ urls: [URL], from view: NSView?, menuOpen: @escaping (Bool) -> Void) -> Bool {
        switch target {
        case .off:
            return false
        case .shareMenu:
            return presentMenu(urls, from: view, menuOpen: menuOpen)
        case .app(let identifier):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                return presentMenu(urls, from: view, menuOpen: menuOpen)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
            return false
        case .airDrop, .service:
            // A service that is gone or cannot take these files falls back to
            // the full menu, so a drop is never lost.
            guard let service = service(for: target, items: urls), service.canPerform(withItems: urls) else {
                return presentMenu(urls, from: view, menuOpen: menuOpen)
            }
            service.delegate = self
            active = service
            // The island never activates the app, so AirDrop's window would
            // otherwise open behind whatever is in front.
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
            return false
        }
    }

    private func presentMenu(_ urls: [URL], from view: NSView?, menuOpen: @escaping (Bool) -> Void) -> Bool {
        guard let view else { return false }
        let presented = presenter.present(for: urls, from: view) { _ in menuOpen(false) }
        if presented { menuOpen(true) }
        return presented
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        if sharingService === active { active = nil }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        if sharingService === active { active = nil }
    }

    // MARK: - Choices

    private func service(for target: NotchSendTarget, items: [Any]) -> NSSharingService? {
        switch target {
        case .airDrop:
            return NSSharingService(named: .sendViaAirDrop)
        case .service(let title):
            return services(for: items).first { $0.title == title }
        case .off, .shareMenu, .app:
            return nil
        }
    }

    private func services(for items: [Any]) -> [NSSharingService] {
        (NSSharingService.self as NotchSharingServiceLookup.Type).sharingServices(forItems: items)
    }

    /// A stand-in file the Share menu is asked about, so Settings lists the
    /// services that take ordinary files.
    private lazy var sampleFile: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vorssaint Send.txt")
        if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
        return url
    }()

    /// AirDrop first, then every other service the Share menu offers for files.
    func options() -> [Option] {
        var options: [Option] = []
        if let airDrop = NSSharingService(named: .sendViaAirDrop) {
            options.append(Option(target: .airDrop, title: airDrop.title, image: airDrop.image))
        }
        var seen = Set(options.map(\.title))
        for service in services(for: [sampleFile]) where !service.title.isEmpty && seen.insert(service.title).inserted {
            options.append(Option(target: .service(service.title), title: service.title, image: service.image))
        }
        for option in options { displayCache[option.id] = option }
        return options
    }

    /// The name and icon the send zone shows for `target`.
    func display(for target: NotchSendTarget) -> Option {
        if let cached = displayCache[target.stored] { return cached }
        let option: Option
        switch target {
        case .off, .shareMenu:
            option = Option(target: target, title: "", image: nil)
        case .airDrop:
            let service = NSSharingService(named: .sendViaAirDrop)
            option = Option(target: target, title: service?.title ?? "AirDrop", image: service?.image)
        case .service(let title):
            let service = services(for: [sampleFile]).first { $0.title == title }
            option = Option(target: target, title: title, image: service?.image)
        case .app(let identifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                return Option(target: target, title: identifier, image: nil)
            }
            option = Option(target: target, title: FileManager.default.displayName(atPath: url.path)
                                .replacingOccurrences(of: ".app", with: ""),
                            image: NSWorkspace.shared.icon(forFile: url.path))
        }
        displayCache[target.stored] = option
        return option
    }

    /// Asks for an app to open dropped files with, from Applications.
    func chooseApp(completion: @escaping (NotchSendTarget?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let identifier = Bundle(url: url)?.bundleIdentifier else { return completion(nil) }
            completion(.app(identifier))
        }
    }
}
