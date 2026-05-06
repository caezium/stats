//
//  HistoryWindow.swift
//  Stats
//
//  Native macOS window showing the time-series history collected by Stats.
//  Reads directly from `DB.shared` (in-process, no HTTP), decodes the JSON
//  payloads with a set of small "mirror" structs so it doesn't depend on
//  the modules' internal types, and renders with Apple's Charts framework.
//
//  Requires macOS 13+ for Charts. Older systems get a one-line stub.
//

import Cocoa
import SwiftUI
import Kit

final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "Stats — History"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.toolbarStyle = .unifiedCompact
        win.center()
        win.setFrameAutosaveName("Stats.HistoryWindow")
        win.minSize = NSSize(width: 720, height: 480)
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        self.init(window: win)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
        guard let win = window else { return }
        win.delegate = self
        let host: NSView
        if #available(macOS 13.0, *) {
            host = NSHostingView(rootView: HistoryRootView())
        } else {
            host = NSHostingView(rootView: HistoryUnsupportedView())
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = NSView()
        win.contentView!.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
            host.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: win.contentView!.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Fallback for macOS < 13

private struct HistoryUnsupportedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("History view requires macOS 13 or newer")
                .font(.title3)
            Text("On older systems, use the dashboard at http://127.0.0.1:9276/ instead.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
