import SwiftUI
import UIKit
import APTerminalClient
import APTerminalProtocol

struct TerminalView: View {
    @ObservedObject var model: iOSClientAppModel
    @EnvironmentObject private var appLockManager: AppLockManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isComposerFocused: Bool
    let session: SessionSummary

    var body: some View {
        ZStack {
            ClientTheme.background
                .ignoresSafeArea()

            VStack(spacing: 10) {
                headerCard

                terminalSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            controlCard
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .background(Color.clear)
        }
        .dynamicTypeSize(.xSmall ... .xLarge)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Theme", selection: $model.terminalTheme) {
                        ForEach(TerminalTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }

                    Button("Copy Output") {
                        UIPasteboard.general.string = model.terminalText
                        appLockManager.markActivity()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(ClientTheme.textPrimary)
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Button("Esc") { sendFromToolbar(.escape) }
                Button("Tab") { sendFromToolbar(.tab) }
                Button("↑") { sendFromToolbar(.arrowUp) }
                Button("↓") { sendFromToolbar(.arrowDown) }
                Button("←") { sendFromToolbar(.arrowLeft) }
                Button("→") { sendFromToolbar(.arrowRight) }
                Button("Ctrl-C") { sendFromToolbar(.ctrl("c")) }
                Spacer()
                Button("Done") {
                    isComposerFocused = false
                }
            }
        }
        .onAppear {
            isComposerFocused = true
        }
        .onDisappear {
            Task {
                await model.detachSessionIfNeeded(session.id)
            }
        }
        .alert(
            model.pendingPasteProtectionPrompt?.title ?? "Confirm Paste",
            isPresented: Binding(
                get: { model.pendingPasteProtectionPrompt != nil },
                set: { isPresented in
                    if isPresented == false {
                        model.cancelPendingPasteProtectionPrompt()
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                model.cancelPendingPasteProtectionPrompt()
            }
            Button("Send") {
                Task {
                    await model.confirmPendingPasteProtectionPrompt()
                    appLockManager.markActivity()
                }
            }
        } message: {
            Text(model.pendingPasteProtectionPrompt?.message ?? "")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(ClientTheme.textPrimary)
                    Text(session.workingDirectory)
                        .font(.caption)
                        .foregroundStyle(ClientTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(interactionModeTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusTint.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 8) {
                metricPill(title: "Source", value: sourceTitle)
                metricPill(title: "State", value: session.state.rawValue.capitalized)
                metricPill(title: "Latency", value: latencyText)
                metricPill(title: "Sent", value: "\(model.inputDiagnostics.successfulEventCount)")
            }
        }
        .padding(14)
        .background(ClientTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
    }

    private var terminalSurface: some View {
        GeometryReader { proxy in
            let viewportSize = sanitizedViewportSize(proxy.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(terminalBackground)

                if viewportSize.width > 0, viewportSize.height > 0 {
                    TerminalTextViewport(
                        text: displayText,
                        foregroundColor: UIColor(terminalForeground),
                        backgroundColor: UIColor.clear
                    )
                    .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.22), radius: 16, y: 8)
            .onAppear {
                reportViewportSize(viewportSize)
            }
            .onChange(of: viewportSize) { _, newSize in
                reportViewportSize(newSize)
            }
        }
    }

    private var controlCard: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickKey("Esc") { sendFromToolbar(.escape) }
                    quickKey("Tab") { sendFromToolbar(.tab) }
                    quickKey("Up") { sendFromToolbar(.arrowUp) }
                    quickKey("Down") { sendFromToolbar(.arrowDown) }
                    quickKey("Left") { sendFromToolbar(.arrowLeft) }
                    quickKey("Right") { sendFromToolbar(.arrowRight) }
                    quickKey("Ctrl-C") { sendFromToolbar(.ctrl("c")) }

                    Menu("Alt") {
                        Button("Alt-B") { sendFromToolbar(.alt("b")) }
                        Button("Alt-D") { sendFromToolbar(.alt("d")) }
                        Button("Alt-F") { sendFromToolbar(.alt("f")) }
                    }
                    .menuStyle(.button)
                    .foregroundStyle(ClientTheme.textPrimary)

                    Menu("Fn") {
                        ForEach(1...12, id: \.self) { number in
                            Button("F\(number)") {
                                sendFromToolbar(.function(number))
                            }
                        }
                    }
                    .menuStyle(.button)
                    .foregroundStyle(ClientTheme.textPrimary)
                }
                .padding(.horizontal, 2)
            }

            VStack(spacing: 10) {
                TextField("Command or input", text: $model.pendingInput, axis: .vertical)
                    .focused($isComposerFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle((model.viewOnlyModeEnabled || session.capabilities.supportsInput == false) ? ClientTheme.textMuted : ClientTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(ClientTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ClientTheme.border, lineWidth: 1)
                    }
                    .disabled(model.viewOnlyModeEnabled || session.capabilities.supportsInput == false)

                HStack(alignment: .center, spacing: 10) {
                    Label(statusLine, systemImage: statusLineImage)
                        .font(.caption)
                        .foregroundStyle(ClientTheme.textSecondary)
                        .lineLimit(2)

                    Spacer()

                    Button(isComposerFocused ? "Hide KB" : "Keyboard") {
                        isComposerFocused.toggle()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClientTheme.accentSecondary)
                }

                HStack(spacing: 10) {
                    secondaryButton(title: "Paste", systemImage: "doc.on.clipboard") {
                        Task {
                            await model.sendClipboardContents()
                            appLockManager.markActivity()
                        }
                    }
                    .disabled(model.viewOnlyModeEnabled || session.capabilities.supportsInput == false)

                    secondaryButton(title: "Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = model.terminalText
                        appLockManager.markActivity()
                    }

                    primaryButton(title: "Send", systemImage: "paperplane.fill", tint: ClientTheme.accent) {
                        Task {
                            await model.sendPendingInput()
                            appLockManager.markActivity()
                        }
                    }
                    .disabled(model.viewOnlyModeEnabled || session.capabilities.supportsInput == false)
                }
            }
        }
        .padding(12)
        .background(ClientTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(ClientTheme.border, lineWidth: 1)
        }
    }

    private var displayText: String {
        model.terminalText.isEmpty ? "No terminal output yet." : model.terminalText
    }

    private var latencyText: String {
        model.inputDiagnostics.lastSendLatencyMilliseconds.map { "\($0) ms" } ?? "n/a"
    }

    private var statusLine: String {
        if session.capabilities.supportsInput == false {
            return "This is a read-only preview of an existing Terminal/iTerm window."
        }

        if model.viewOnlyModeEnabled {
            return "View-only mode blocks typing and control keys."
        }

        if let failure = model.inputDiagnostics.lastFailureSummary {
            return "Last failure: \(failure)"
        }

        return model.inputDiagnostics.summaryText
    }

    private var statusLineImage: String {
        if session.capabilities.supportsInput == false {
            return "eye"
        }

        if model.viewOnlyModeEnabled {
            return "eye.slash"
        }

        if model.inputDiagnostics.lastFailureSummary != nil {
            return "exclamationmark.triangle"
        }

        return "waveform.path.ecg"
    }

    private var statusTint: Color {
        if session.capabilities.supportsInput == false {
            return ClientTheme.warning
        }

        return model.viewOnlyModeEnabled ? ClientTheme.warning : ClientTheme.accent
    }

    private var interactionModeTitle: String {
        if session.capabilities.supportsInput == false {
            return "Preview Only"
        }

        return model.viewOnlyModeEnabled ? "View Only" : "Interactive"
    }

    private var sourceTitle: String {
        switch session.source {
        case .managed:
            return "Managed"
        case .terminalApp:
            return "Terminal"
        case .iTermApp:
            return "iTerm"
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ClientTheme.textMuted)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClientTheme.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(ClientTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func quickKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClientTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ClientTheme.surfaceRaised, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(ClientTheme.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(model.viewOnlyModeEnabled || session.capabilities.supportsInput == false)
    }

    private func secondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClientTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(ClientTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ClientTheme.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sendFromToolbar(_ key: TerminalSpecialKey) {
        guard model.viewOnlyModeEnabled == false, session.capabilities.supportsInput else { return }

        Task {
            await model.sendSpecialKey(key)
            appLockManager.markActivity()
        }
    }

    private func reportViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else {
            return
        }

        guard size.width > 0, size.height > 0 else {
            return
        }

        Task {
            await model.updateTerminalViewport(sessionID: session.id, availableSize: size)
        }
    }

    private var terminalBackground: Color {
        switch model.terminalTheme {
        case .system:
            return Color(red: 0.06, green: 0.08, blue: 0.10)
        case .paper:
            return Color(red: 0.92, green: 0.90, blue: 0.84)
        case .night:
            return Color(red: 0.03, green: 0.05, blue: 0.06)
        }
    }

    private var terminalForeground: Color {
        switch model.terminalTheme {
        case .system:
            return Color(red: 0.84, green: 0.95, blue: 0.90)
        case .paper:
            return Color(red: 0.18, green: 0.16, blue: 0.12)
        case .night:
            return Color(red: 0.62, green: 0.94, blue: 0.74)
        }
    }

    private func sanitizedViewportSize(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        return CGSize(width: width, height: height)
    }
}

private struct TerminalTextViewport: UIViewRepresentable {
    let text: String
    let foregroundColor: UIColor
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = backgroundColor
        textView.textColor = foregroundColor
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = true
        textView.showsVerticalScrollIndicator = true
        textView.showsHorizontalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.lineBreakMode = .byClipping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            let previousText = textView.text ?? ""
            let previousOffset = textView.contentOffset
            let shouldStickToBottom = previousOffset.y >= max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height - 24)
            textView.text = text
            textView.textColor = foregroundColor
            textView.backgroundColor = backgroundColor
            textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.layoutIfNeeded()

            if shouldAutoScrollToBottom(previousText: previousText, newText: text) || shouldStickToBottom {
                let maxOffsetY = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
                textView.setContentOffset(CGPoint(x: previousOffset.x, y: maxOffsetY), animated: false)
            } else {
                let clampedY = max(-textView.adjustedContentInset.top, min(previousOffset.y, textView.contentSize.height))
                textView.setContentOffset(CGPoint(x: previousOffset.x, y: clampedY), animated: false)
            }
        } else {
            textView.textColor = foregroundColor
            textView.backgroundColor = backgroundColor
        }
    }

    private func shouldAutoScrollToBottom(previousText: String, newText: String) -> Bool {
        guard newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }

        if previousText.isEmpty {
            return true
        }

        return previousText.localizedCaseInsensitiveContains("loading preview")
    }
}
