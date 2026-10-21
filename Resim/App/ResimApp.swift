import SwiftUI
import AppKit

@main
struct ResimApp: App {
    @NSApplicationDelegateAdaptor(ResimAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() { LaunchDiagnostics.begin() }

    var body: some Scene {
        Window("Resim", id: "main") {
            MainView(model: model)
                .onAppear {
                    appDelegate.model = model
                    LaunchDiagnostics.viewReady()
                }
                .onOpenURL { model.addURLs([$0]) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 620, height: 400)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { ImagePicker.present(model: model) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Button("Cancel Processing") { model.cancelAll() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!model.hasActiveJobs)
                Button("Clear List") { model.clearFinished() }
                    .disabled(model.finishedCount == 0)
            }
        }
        Settings { SettingsView(model: model) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 780, height: 520)
            .windowResizability(.contentMinSize)
    }
}

@MainActor
final class ResimAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var awaitingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.configureAppearance()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveJobs else { return .terminateNow }
        guard !awaitingTermination else { return .terminateLater }
        let alert = CloseProtection.alert()
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        awaitingTermination = true
        model.cancelAll()
        Task { @MainActor in
            await CloseProtection.waitForCleanup(model)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
enum CloseProtection {
    static func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Images are still processing")
        alert.informativeText = String(localized: "You can keep working or cancel processing and close. Changes already saved are preserved.")
        alert.addButton(withTitle: String(localized: "Keep Working"))
        alert.addButton(withTitle: String(localized: "Cancel and Close"))
        alert.alertStyle = .warning
        return alert
    }

    static func waitForCleanup(_ model: AppModel) async {
        while model.hasActiveJobs {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

struct WindowCloseObserver: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WindowHook {
        let view = WindowHook()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ nsView: WindowHook, context: Context) {}
    static func dismantleNSView(_ nsView: WindowHook, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class WindowHook: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                // SwiftUI installs its own delegate while constructing the window. Attach after
                // that construction, preserving its delegate for all other window behavior.
                Task { @MainActor [weak self, weak window] in
                    await Task.yield()
                    guard let self, let window, self.window === window else { return }
                    self.onWindow?(window)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        // AppKit invokes its delegate proxy on the main thread. NSObject forwarding itself
        // is nonisolated; keep the weak reference available to that ObjC entry point.
        nonisolated(unsafe) weak var previousDelegate: (any NSWindowDelegate)?
        weak var window: NSWindow?
        private var asking = false
        private var escapeMonitor: Any?
        init(model: AppModel) { self.model = model }
        func attach(_ window: NSWindow) {
            guard self.window !== window || window.delegate !== self else { return }
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            window.setFrameAutosaveName("ResimMainWindow")
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            if escapeMonitor == nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                    let handled = MainActor.assumeIsolated {
                        guard let self, let window = self.window, event.window === window,
                              window.attachedSheet == nil, self.model.hasActiveJobs else { return false }
                        self.model.cancelAll()
                        return true
                    }
                    return handled ? nil : event
                }
            }
        }
        func detach() {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            if let window, window.delegate === self { window.delegate = previousDelegate }
        }
        override nonisolated func responds(to selector: Selector!) -> Bool {
            MainActor.assumeIsolated {
                super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
            }
        }
        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.hasActiveJobs else { return previousDelegate?.windowShouldClose?(sender) ?? true }
            guard !asking else { return false }
            asking = true
            CloseProtection.alert().beginSheetModal(for: sender) { [weak self, weak sender] response in
                guard let self else { return }
                self.asking = false
                guard response == .alertSecondButtonReturn else { return }
                self.model.cancelAll()
                Task { @MainActor in
                    await CloseProtection.waitForCleanup(self.model)
                    sender?.performClose(nil)
                }
            }
            return false
        }
    }
}
