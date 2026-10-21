import SwiftUI
import AppKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .privacy: String(localized: "Privacy")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .privacy: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .privacy: .green
        case .about: .blue
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var page: SettingsPage = .general
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 28)
                    .padding(.top, 26)
                    .padding(.bottom, 22)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch page {
                        case .general: generalSettings
                        case .privacy: privacySettings
                        case .about: aboutSettings
                        }
                    }
                    .frame(maxWidth: 580, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }

                if page != .about {
                    Text("Changes apply to images you add from now on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SettingsPalette.content(colorScheme))
        }
        .frame(minWidth: 760, minHeight: 500)
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(SettingsWindowAppearance(page: page).frame(width: 0, height: 0))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SettingsLogo(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Resim").font(.headline)
                    Text("Settings").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 54)
            .padding(.bottom, 24)

            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    if item == .about {
                        Divider().padding(.horizontal, 8).padding(.vertical, 8)
                    }
                    Button { page = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityHidden(true)
                            Text(item.title).font(.system(size: 13, weight: page == item ? .medium : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(SettingsSidebarButtonStyle(selected: page == item))
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .accessibilityIdentifier("settings-\(item.rawValue)")
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 20)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebar(colorScheme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    private var generalSettings: some View {
        Group {
            SettingsSection(title: String(localized: "Optimization")) {
                SettingsRow {
                    HStack {
                        Text("Mode")
                        Spacer(minLength: 16)
                        Picker("Mode", selection: $model.settings.mode) {
                            Text("Automatic").tag(OptimizationMode.automatic)
                            Text("Lossless").tag(OptimizationMode.lossless)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings-optimization-mode")
                    }
                }
                if model.settings.mode == .automatic {
                    SettingsDivider()
                    SettingsRow {
                        HStack {
                            Text("Compression profile")
                            Spacer(minLength: 16)
                            Picker("Compression profile", selection: $model.settings.profile) {
                                ForEach(CompressionProfile.allCases, id: \.self) { profile in
                                    Text(profile.title).tag(profile)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("settings-compression-profile")
                        }
                    }
                }
                SettingsDivider()
                Text(model.settings.mode == .automatic
                     ? model.settings.profile.description
                     : String(localized: "Preserves the image. Some images may not become smaller."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                if model.settings.mode == .automatic {
                    SettingsDivider()
                    Text("Keeps the original format and dimensions. PNG, GIF and SVG always use lossless optimization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
            }

            SettingsSection(title: String(localized: "Files")) {
                SettingsRow {
                    HStack {
                        Text("Save images")
                        Spacer(minLength: 16)
                        Picker("Save images", selection: destinationChoice) {
                            Text("Modify original").tag(FileSaveMode.replaceOriginal)
                            Text("Copy next to the original").tag(FileSaveMode.copyBesideOriginal)
                            Text("Copy to a folder…").tag(FileSaveMode.copyToFolder)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings-save-images")
                    }
                }
                if model.settings.fileSaveMode == .copyToFolder, let destination = model.settings.destination {
                    SettingsDivider()
                    SettingsRow {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(verbatim: destination.path(percentEncoded: false))
                                .font(.callout)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(destination.path(percentEncoded: false))
                            Spacer(minLength: 0)
                            Button("Choose…", action: chooseDestination)
                                .accessibilityIdentifier("settings-choose-folder")
                        }
                    }
                }
                SettingsDivider()
                Text(model.settings.fileSaveMode == .replaceOriginal
                     ? String(localized: "Replaces the original file only when the optimized image is smaller and passes validation. Keeps the same name and location.")
                     : String(localized: "Original files are preserved. Copies are saved only when they are smaller and pass validation."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
    }

    private var privacySettings: some View {
        Group {
            SettingsSection(title: String(localized: "Metadata")) {
                SettingsRow {
                    HStack {
                        Text("Remove personal metadata")
                        Spacer(minLength: 16)
                        Toggle("Remove personal metadata", isOn: $model.settings.stripPersonalMetadata)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("settings-remove-metadata")
                    }
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keeps the data needed to display the image. Does not remove information within the pixels.")
                    Text("HEIC and SVG images require this option to be turned off.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            }

            Label {
                Text("Your images are processed on your Mac and are never uploaded.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var aboutSettings: some View {
        Group {
            HStack(alignment: .center, spacing: 16) {
                SettingsLogo(size: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: "Resim").font(.title2.weight(.semibold))
                    Text(String.localizedStringWithFormat(String(localized: "Version %@"),
                         Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                        .foregroundStyle(.secondary)
                    Text("Local image optimization for macOS.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: String(localized: "Project")) {
                SettingsRow {
                    HStack {
                        Text("Official website")
                        Spacer(minLength: 12)
                        Link(destination: URL(string: "https://resim.nicoandrade.com/")!) {
                            Text(verbatim: "resim.nicoandrade.com")
                        }
                        .accessibilityIdentifier("settings-official-website")
                    }
                }
                SettingsDivider()
                SettingsRow {
                    HStack {
                        Text("Created by")
                        Spacer(minLength: 12)
                        Link(destination: URL(string: "https://nicoandrade.com")!) {
                            Text(verbatim: "Nico Andrade")
                        }
                        .accessibilityIdentifier("settings-creator")
                    }
                }
            }

            SettingsSection(title: String(localized: "Supported formats")) {
                SettingsRow { Text("PNG, JPEG, WebP, HEIC, AVIF, GIF, and SVG") }
            }

            SettingsSection(title: String(localized: "Acknowledgments")) {
                SettingsRow {
                    HStack {
                        Text("Third-party software")
                        Spacer(minLength: 12)
                        Button("Third-Party Licenses") {
                            if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md", subdirectory: "Licenses") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .accessibilityIdentifier("settings-licenses")
                    }
                }
            }
        }
    }

    private var destinationChoice: Binding<FileSaveMode> {
        Binding(get: { model.settings.fileSaveMode }, set: { choice in
            if choice == .copyToFolder, model.settings.destination == nil {
                chooseDestination()
            } else {
                model.settings.fileSaveMode = choice
            }
        })
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Destination Folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.destination
        panel.begin { response in
            if response == .OK, let url = panel.url {
                model.settings.destination = url
                model.settings.fileSaveMode = .copyToFolder
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsPalette.card(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.horizontal, 14)
    }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(SettingsPalette.selection(colorScheme)
                .opacity(selected ? 1 : (hovered || configuration.isPressed ? 0.5 : 0)),
                        in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
}

private enum SettingsPalette {
    static func content(_ scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.12 : 1)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.15 : 0.96)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.16 : 0.975)
    }

    static func selection(_ scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.22 : 0.92)
    }
}

private struct SettingsLogo: View {
    let size: CGFloat

    var body: some View {
        Image("ResimSymbol")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(LinearGradient(
                colors: [Color(red: 1, green: 0.72157, blue: 0.36078),
                         Color(red: 0.91373, green: 0.32941, blue: 0.43922)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct SettingsWindowAppearance: NSViewRepresentable {
    let page: SettingsPage

    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.configureAfterUpdate() }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureAfterUpdate()
        }

        func configureAfterUpdate() {
            // SwiftUI can restore the Settings title when the selected page changes.
            // Apply after that update as well as after the window is first installed.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.configureWindow()
            }
        }

        func configureWindow() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }
}

#Preview("General") {
    let model = AppModel(defaults: UserDefaults(suiteName: "Resim.SettingsPreview.General")!)
    model.settings = OptimizationSettings()
    return SettingsView(model: model)
        .frame(width: 780, height: 520)
        .preferredColorScheme(.light)
}

#Preview("Custom folder · Dark") {
    let model = AppModel(defaults: UserDefaults(suiteName: "Resim.SettingsPreview.Folder")!)
    model.settings = OptimizationSettings(mode: .lossless,
        destination: URL(filePath: "/Volumes/Photos/Optimized Images"))
    return SettingsView(model: model)
        .frame(width: 780, height: 520)
        .preferredColorScheme(.dark)
}
