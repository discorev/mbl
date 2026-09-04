import AppKit
import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
private final class CompanionWindowState {
    var updateState: Updater.State = .idle
    var updaterAvailable = false
    var codexDraft = ""
    var localDraft = ""
    var originalCodex = ""
    var originalLocal = ""
    var codexSource: CompanionStore.PromptSnapshot?
    var localSource: CompanionStore.PromptSnapshot?
    var draftsLoaded = false
}

@MainActor
final class CompanionWindowController: NSObject, NSWindowDelegate {
    private let store: CompanionStore
    private let state = CompanionWindowState()
    private let window: NSWindow
    private var refreshTask: Task<Void, Never>?

    var updateState: Updater.State {
        get { state.updateState }
        set { state.updateState = newValue }
    }
    var updaterAvailable: Bool {
        get { state.updaterAvailable }
        set { state.updaterAvailable = newValue }
    }

    init(store: CompanionStore, onResetHUD: @escaping () -> Void, onUpdateAction: @escaping () -> Void) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 566),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "mbl"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 520)
        window.setFrameAutosaveName("mblCompanionWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: CompanionView(store: store, state: state,
            onResetHUD: onResetHUD, onUpdateAction: onUpdateAction))
        if !window.setFrameUsingName("mblCompanionWindow") { window.center() }
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refreshTask == nil {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    guard let self else { break }
                    if self.window.isVisible { self.store.refresh() }
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        refreshTask?.cancel()
        refreshTask = nil
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { store.refresh() }
}

private enum CompanionPage: String, CaseIterable {
    case history = "History", vocabulary = "Vocabulary", cleanup = "Cleanup", settings = "Settings"
    var icon: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .vocabulary: "book"
        case .cleanup: "wand.and.stars"
        case .settings: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .history: "Stored on this Mac"
        case .vocabulary: "Applies to future dictations"
        case .cleanup: "How your words are tidied"
        case .settings: "Changes apply automatically"
        }
    }
}

private let companionAccent = Color(red: 0.46, green: 0.34, blue: 0.79)

@MainActor
private struct CompanionView: View {
    @Bindable var store: CompanionStore
    var state: CompanionWindowState
    var onResetHUD: () -> Void
    var onUpdateAction: () -> Void
    @State private var page: CompanionPage = .history

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(page.rawValue).fontWeight(.semibold)
                    Spacer()
                    Text(page.subtitle).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 26).frame(height: 58)
                Divider()
                Group {
                    switch page {
                    case .history: CompanionHistoryView(store: store)
                    case .vocabulary: CompanionVocabularyView(store: store)
                    case .cleanup: CompanionCleanupView(store: store, state: state)
                    case .settings: CompanionSettingsView(store: store, updaterAvailable: state.updaterAvailable, onResetHUD: onResetHUD)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                LinearGradient(colors: [.orange, .pink, .purple, .indigo, .cyan], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 3).accessibilityHidden(true)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(companionAccent)
        .ignoresSafeArea(.container, edges: .top)
        .alert("mbl needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                Text("mbl").font(.system(size: 26, weight: .bold, design: .rounded))
            }.padding(.leading, 9).padding(.top, 61).padding(.bottom, 31)
            ForEach(CompanionPage.allCases, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon).frame(width: 17)
                        Text(item.rawValue).fontWeight(.medium)
                        Spacer()
                    }.padding(.horizontal, 11).padding(.vertical, 10)
                        .foregroundStyle(page == item ? companionAccent : Color.secondary)
                        .background(page == item ? companionAccent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).padding(.bottom, 5)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer()
            HStack {
                Text("mbl \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if state.updaterAvailable {
                    switch state.updateState {
                    case .available(let version):
                        updateButton("arrow.down.to.line", label: "Download mbl \(version)")
                    case .ready:
                        updateButton("arrow.clockwise", label: "Restart to install update")
                    case .downloading, .checking:
                        ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                            .help(state.updateState == .downloading ? "Downloading update…" : "Checking for updates…")
                    default: EmptyView()
                    }
                }
            }.frame(height: 20).padding(.leading, 10).padding(.top, 12).padding(.bottom, 17)
        }.padding(.horizontal, 12).frame(width: 190)
            .background(companionAccent.opacity(0.07))
    }

    private func updateButton(_ symbol: String, label: String) -> some View {
        Button(action: onUpdateAction) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20, alignment: .center)
                .foregroundStyle(.white).background(companionAccent, in: Circle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

@MainActor
private struct CompanionHistoryView: View {
    var store: CompanionStore
    @State private var query = ""
    @State private var selection: String?
    @State private var copied = false
    @State private var originalExpanded = true
    @State private var pendingDeletion: HistoryEntry?
    private var filtered: [HistoryEntry] {
        store.history.filter { query.isEmpty || ($0.raw + " " + ($0.cleaned ?? "")).localizedCaseInsensitiveContains(query) }
    }
    private var selected: HistoryEntry? { filtered.first(where: { $0.id == selection }) ?? filtered.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search dictations", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search dictations")
                Text("RECENT DICTATIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(dateLabel(entry.ts)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(entry.cleaned ?? entry.raw).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                            Text("\(backendLabel(entry.backend)) · \(entry.audioSeconds, specifier: "%.1f")s").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .contentShape(Rectangle())
                            .tag(entry.id)
                            .listRowInsets(EdgeInsets())
                            .contextMenu {
                                Button("Delete", role: .destructive) { pendingDeletion = entry }
                            }
                    }
                }
                .listStyle(.plain)
                .onDeleteCommand { if let entry = selected { pendingDeletion = entry } }
            }.padding(12).frame(width: 225)
            Divider()
            if let entry = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        HStack {
                            Text("\(dateLabel(entry.ts)) · \(entry.audioSeconds, specifier: "%.1f")s recording")
                            Spacer()
                            Text(backendLabel(entry.backend)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(companionAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("FINAL TEXT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text(entry.cleaned ?? entry.raw).font(.system(size: 19)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(copied ? "Copied" : "Copy text") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(entry.cleaned ?? entry.raw, forType: .string)
                        }
                        Divider().padding(.top, 5)
                        DisclosureGroup("Original transcript", isExpanded: $originalExpanded) {
                            Text(entry.raw).textSelection(.enabled).font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.system(size: 11))
                        if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        Text(timingLabel(entry))
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 8)
                    }.padding(24)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = entry }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            } else {
                ContentUnavailableView(query.isEmpty ? "No dictations yet" : "No matching dictations", systemImage: "waveform", description: Text(query.isEmpty ? "Hold your push-to-talk key to start. Your words will appear here." : "Try another word."))
            }
        }
        .onChange(of: selected?.id) { _, _ in copied = false }
        .confirmationDialog("Delete dictation?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { entry in
            Button("Delete", role: .destructive) { delete(entry); pendingDeletion = nil }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { entry in
            Text("This permanently deletes the dictation from \(dateLabel(entry.ts)). This cannot be undone.")
        }
    }

    private func delete(_ entry: HistoryEntry) {
        let entries = filtered
        let wasSelected = selected?.id == entry.id
        let index = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        do {
            try store.removeHistoryEntry(entry)
            if wasSelected {
                let remaining = filtered
                selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
                copied = false
            }
        } catch {
            store.errorMessage = "Could not delete dictation: \(error.localizedDescription)"
        }
    }

    private func timingLabel(_ entry: HistoryEntry) -> String {
        var label = "Transcribed on-device in " + String(format: "%.1f", Double(entry.transcribeMs) / 1000) + "s"
        if let cleanupMs = entry.cleanupMs {
            label += " · Cleaned in " + String(format: "%.1f", Double(cleanupMs) / 1000) + "s"
        }
        if entry.fallback { label += " · Fallback used" }
        return label
    }
    private func backendLabel(_ backend: TranscriptBackend) -> String {
        switch backend { case .codex: "Codex"; case .local: "On-device"; case .raw: "Original" }
    }
    private func dateLabel(_ value: String) -> String {
        let date = HistoryTimestamp.date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

@MainActor
private struct CompanionVocabularyView: View {
    @Bindable var store: CompanionStore
    @State private var word = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeading("Words worth getting right.", subtitle: "Names, products and phrases you use. One term at a time.")
                HStack {
                    TextField("Add a name or term", text: $word).textFieldStyle(.roundedBorder).onSubmit(addWord)
                    Button("Add word", action: addWord).buttonStyle(.borderedProminent).disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if store.vocabulary.isEmpty {
                    Text("Add your first name or term above.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.vocabulary, id: \.self) { term in
                            HStack {
                                Text(term).textSelection(.enabled)
                                Spacer()
                                Button { attempt { try store.removeWord(term) } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(term)").accessibilityLabel("Remove \(term)")
                            }.padding(13)
                            if term != store.vocabulary.last { Divider() }
                        }
                    }.background(.background, in: RoundedRectangle(cornerRadius: 9))
                }
                Text("Your vocabulary is included when mbl cleans up a dictation.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    private func addWord() { attempt { try store.addWord(word); word = "" } }
    private func attempt(_ action: () throws -> Void) { do { try action() } catch { store.errorMessage = error.localizedDescription } }
}

@MainActor
private struct CompanionCleanupView: View {
    @Bindable var store: CompanionStore
    @Bindable var state: CompanionWindowState
    @State private var saved = false
    @State private var confirmingReload = false
    @State private var reloadBackend: CleanupBackend = .codex
    private var source: CompanionStore.PromptSnapshot? { store.config.backend == .codex ? state.codexSource : state.localSource }
    private var original: String { store.config.backend == .codex ? state.originalCodex : state.originalLocal }
    private var latest: String { store.config.backend == .codex ? store.codexPrompt : store.localPrompt }
    private var isDirty: Bool { draft.wrappedValue != original }
    private var draft: Binding<String> {
        Binding(get: { store.config.backend == .codex ? state.codexDraft : state.localDraft }, set: {
            if store.config.backend == .codex { state.codexDraft = $0 } else { state.localDraft = $0 }; saved = false
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeading("Still sounds like you.", subtitle: "Choose how mbl tidies your speech before typing it.")
                VStack(spacing: 0) {
                    settingRow("Clean up with", subtitle: store.config.backend == .codex ? "Transcripts are sent to Codex for cleanup." : "Cleanup stays on this Mac.") {
                        Picker("Clean up with", selection: Binding(get: { store.config.backend }, set: { value in store.updateConfig { $0.backend = value } })) {
                            Text("Codex").tag(CleanupBackend.codex)
                            Text("On-device").tag(CleanupBackend.local)
                        }.labelsHidden().frame(width: 150)
                    }
                    Divider()
                    settingRow("Use on-device fallback", subtitle: "If Codex is unavailable, keep dictating locally.") {
                        Toggle("Use on-device fallback", isOn: Binding(get: { store.config.fallback == .local }, set: { value in store.updateConfig { $0.fallback = value ? .local : .none } }))
                            .labelsHidden().toggleStyle(.switch).disabled(store.config.backend == .local)
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 9))
                Text("Cleanup instructions · \(store.config.backend == .codex ? "Codex" : "On-device")").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                TextEditor(text: draft).font(.system(size: 12)).padding(8).frame(minHeight: 160)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary)).accessibilityLabel("Cleanup instructions")
                HStack {
                    Text("Applies to your next dictation.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload instructions") {
                        reloadBackend = store.config.backend
                        if isDirty { confirmingReload = true } else { reloadInstructions(reloadBackend) }
                    }.disabled(source != nil && !isDirty && original == latest)
                    Button(saved ? "Instructions saved" : "Save instructions") {
                        do {
                            guard let source else {
                                throw CompanionStoreError.invalid("These instructions could not be loaded. Choose Reload instructions before saving.")
                            }
                            try store.savePrompt(draft.wrappedValue, original: source)
                            if store.config.backend == .codex { state.originalCodex = state.codexDraft; state.codexSource = .init(url: source.url, text: state.codexDraft) }
                            else { state.originalLocal = state.localDraft; state.localSource = .init(url: source.url, text: state.localDraft) }
                            if store.config.backend == .codex, state.codexSource != store.promptSnapshot(for: .codex) {
                                adoptInstructions(.codex)
                            } else { saved = true }
                        }
                        catch { store.errorMessage = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28)
        }.onAppear {
            if !state.draftsLoaded || state.codexDraft == state.originalCodex {
                adoptInstructions(.codex)
            }
            if !state.draftsLoaded || state.localDraft == state.originalLocal {
                adoptInstructions(.local)
            }
            state.draftsLoaded = true
        }
        .confirmationDialog("Discard unsaved instructions?", isPresented: $confirmingReload, titleVisibility: .visible) {
            Button("Discard and reload", role: .destructive) { reloadInstructions(reloadBackend) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces your edits with the instructions currently saved on this Mac.")
        }
        .onChange(of: store.config.backend) { _, _ in saved = false }
        .onChange(of: store.promptSnapshot(for: .codex)) { _, _ in
            if state.codexDraft == state.originalCodex && state.codexSource != store.promptSnapshot(for: .codex) { adoptInstructions(.codex) }
        }
        .onChange(of: store.promptSnapshot(for: .local)) { _, _ in
            if state.localDraft == state.originalLocal && state.localSource != store.promptSnapshot(for: .local) { adoptInstructions(.local) }
        }
    }
    private func reloadInstructions(_ backend: CleanupBackend) {
        store.refresh()
        adoptInstructions(backend)
    }
    private func adoptInstructions(_ backend: CleanupBackend) {
        guard let source = store.promptSnapshot(for: backend) else { return }
        if backend == .codex {
            state.codexDraft = source.text
            state.originalCodex = source.text
            state.codexSource = source
        } else {
            state.localDraft = source.text
            state.originalLocal = source.text
            state.localSource = source
        }
        saved = false
    }
}

@MainActor
private struct CompanionSettingsView: View {
    @Bindable var store: CompanionStore
    var updaterAvailable: Bool
    var onResetHUD: () -> Void
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = AXIsProcessTrusted()
    @State private var inputMonitoring = CGPreflightListenEventAccess()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeading("Make yourself comfortable.", subtitle: "A few small choices for everyday dictation.")
                sectionLabel("Dictation")
                VStack(spacing: 0) {
                    settingRow("Push-to-talk key", subtitle: "Hold to talk. Release to type.") {
                        Picker("Push-to-talk key", selection: Binding(get: { store.config.hotkey }, set: { value in store.updateConfig { $0.hotkey = value } })) {
                            Text("⌥ Right Option").tag(HotkeyKey.rightOption)
                            Text("⌃ Right Control").tag(HotkeyKey.rightControl)
                        }.labelsHidden().frame(width: 160)
                    }
                    Divider()
                    settingRow("Dictation indicator", subtitle: "Drag it anywhere on your screen.") { Button("Reset position", action: onResetHUD) }
                }.background(.background, in: RoundedRectangle(cornerRadius: 9))
                settingRow("Configuration files", subtitle: "Edit settings, prompts, vocabulary and history directly.") {
                    Button("Open config folder") { NSWorkspace.shared.open(store.directoryURL) }
                }.background(.background, in: RoundedRectangle(cornerRadius: 9))
                sectionLabel("Access")
                VStack(spacing: 0) {
                    permissionRow("Microphone", subtitle: "To hear you while you hold the key.", allowed: microphone == .authorized, pane: "Privacy_Microphone")
                    Divider()
                    permissionRow("Accessibility", subtitle: "To type at the cursor.", allowed: accessibility, pane: "Privacy_Accessibility")
                    Divider()
                    permissionRow("Input monitoring", subtitle: "To detect your push-to-talk key.", allowed: inputMonitoring, pane: "Privacy_ListenEvent")
                }.background(.background, in: RoundedRectangle(cornerRadius: 9))
                sectionLabel("Updates")
                settingRow("Download updates automatically", subtitle: updaterAvailable ? "You choose when to install them." : "Updates are available in installed release builds.") {
                    Toggle("Download updates automatically", isOn: Binding(get: { store.config.autoDownloadUpdates }, set: { value in store.updateConfig { $0.autoDownloadUpdates = value } }))
                        .labelsHidden().toggleStyle(.switch).disabled(!updaterAvailable)
                }.background(.background, in: RoundedRectangle(cornerRadius: 9))
            }.padding(28)
        }.onAppear(perform: refreshPermissions)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }
    private func permissionRow(_ title: String, subtitle: String, allowed: Bool, pane: String) -> some View {
        settingRow(title, subtitle: subtitle) {
            if allowed { Label("Allowed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
            else {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }.help("Allow \(title) in System Settings")
            }
        }
    }
    private func refreshPermissions() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }
}

private func pageHeading(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 21, weight: .semibold))
        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

private func sectionLabel(_ title: String) -> some View {
    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
}

private func settingRow<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 20) {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        content()
    }.padding(.horizontal, 16).padding(.vertical, 13)
}
