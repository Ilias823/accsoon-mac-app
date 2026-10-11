import AppKit
import CineEyeVideo
import SwiftUI
import UniformTypeIdentifiers

enum GridKind: String, CaseIterable {
    case off, thirds, center, safe

    var title: String {
        switch self {
        case .off: "Off"
        case .thirds: "Rule of Thirds"
        case .center: "Centre Cross"
        case .safe: "Safe Areas"
        }
    }

    var next: GridKind {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

@main
struct AccsoonMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var client = StreamClient()
    @AppStorage("showInfo") private var showInfo = true
    @AppStorage("transmitterHost") private var host = ""
    @AppStorage("grid") private var grid = GridKind.off
    @AppStorage("falseColor") private var falseColor = false
    @AppStorage("zebra") private var zebra = false
    @AppStorage("zebraLevel") private var zebraLevel = 95
    @AppStorage("lutEnabled") private var lutEnabled = false
    @AppStorage("lutPath") private var lutPath = ""
    @AppStorage("systemRenderer") private var systemRenderer = false

    private var rendererOptions: VideoRenderer.Options {
        VideoRenderer.Options(falseColor: falseColor, zebra: zebra, zebraLevel: Float(zebraLevel) / 100, lutEnabled: lutEnabled)
    }

    private var lutName: String? {
        lutEnabled && !lutPath.isEmpty ? URL(fileURLWithPath: lutPath).deletingPathExtension().lastPathComponent : nil
    }

    var body: some Scene {
        Window("Accsoon Monitor", id: "monitor") {
            MonitorView(client: client, showInfo: showInfo, grid: grid, falseColor: falseColor && toolsAvailable,
                        lutName: toolsAvailable ? lutName : nil, useSystemLayer: !toolsAvailable)
                .frame(minWidth: 480, minHeight: 270)
                .onAppear {
                    delegate.client = client
                    client.manualHost = host
                    client.useSystemLayer = systemRenderer
                    client.renderer?.setOptions(rendererOptions)
                    loadLUT(reportErrors: false)
                    client.start()
                }
                .onChange(of: host) { _, new in client.manualHost = new }
                .onChange(of: systemRenderer) { _, new in client.useSystemLayer = new }
                .onChange(of: rendererOptions) { _, new in client.renderer?.setOptions(new) }
                .onChange(of: lutPath) { _, _ in loadLUT(reportErrors: true) }
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Show Info Overlay", isOn: $showInfo).keyboardShortcut("i")
            }
            CommandGroup(replacing: .newItem) {
                Button(client.recording.isRecording ? "Stop Recording" : "Start Recording") {
                    client.recording.isRecording ? client.recorder.stop() : client.recorder.start()
                }
                .keyboardShortcut("r")
                .disabled(client.status != .live && !client.recording.isRecording)
                Button("Show Recordings in Finder") {
                    try? FileManager.default.createDirectory(at: Recorder.folder, withIntermediateDirectories: true)
                    if let file = client.recording.lastFile, FileManager.default.fileExists(atPath: file.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        NSWorkspace.shared.open(Recorder.folder)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Tools") {
                Toggle("False Colour", isOn: $falseColor).keyboardShortcut("f", modifiers: [])
                Toggle("Zebra", isOn: $zebra).keyboardShortcut("z", modifiers: [])
                Picker("Zebra Level", selection: $zebraLevel) {
                    ForEach([70, 80, 90, 95, 100], id: \.self) { Text("\($0)%").tag($0) }
                }
                Divider()
                Toggle("Apply LUT", isOn: $lutEnabled).keyboardShortcut("l", modifiers: []).disabled(lutPath.isEmpty)
                Button("Load LUT…") { chooseLUT() }.keyboardShortcut("o")
                if !lutPath.isEmpty {
                    Text(URL(fileURLWithPath: lutPath).lastPathComponent)
                }
                Divider()
                Picker("Grid", selection: $grid) {
                    ForEach(GridKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Next Grid") { grid = grid.next }.keyboardShortcut("g", modifiers: [])
            }
        }
        Settings {
            Form {
                TextField("Transmitter address", text: $host, prompt: Text("Automatic (Wi-Fi router)"))
                Text("Leave empty to use the router of the current Wi-Fi network, which is the transmitter when you are joined to its network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Use the basic renderer", isOn: $systemRenderer)
                Text("Turns off LUT, false colour and zebra. Try it if the picture misbehaves.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TransmitterSettingsView(client: client)
            }
            .formStyle(.grouped)
            .frame(width: 480)
        }
    }

    private var toolsAvailable: Bool { !systemRenderer && client.renderer != nil }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "Choose a 3D LUT (.cube)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if lutPath == url.path {
            loadLUT(reportErrors: true)  // same file picked again: re-read it
        } else {
            lutPath = url.path
        }
        lutEnabled = true
    }

    private func loadLUT(reportErrors: Bool) {
        guard !lutPath.isEmpty else {
            client.renderer?.setLUT(nil)
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: lutPath))
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            client.renderer?.setLUT(try CubeLUT(text: text))
        } catch {
            client.renderer?.setLUT(nil)
            let name = URL(fileURLWithPath: lutPath).lastPathComponent
            lutPath = ""
            lutEnabled = false
            guard reportErrors else { return }
            let alert = NSAlert()
            alert.messageText = "Could not load \(name)"
            alert.informativeText = Self.describe(error)
            alert.runModal()
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? CubeLUT.ParseError {
        case .notA3DLUT: "This is a 1D LUT. Only 3D .cube LUTs are supported."
        case .badSize: "The file has no valid LUT_3D_SIZE line."
        case .wrongEntryCount(let expected, let found): "The file should contain \(expected) colour entries but has \(found)."
        case nil: error.localizedDescription
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var client: StreamClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finish the movie file before quitting, or its last moments are lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let client, client.recording.isRecording else { return .terminateNow }
        client.recorder.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { client?.stop() }
}
