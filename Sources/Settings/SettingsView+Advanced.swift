import AppKit
import DesignSystem
import Diagnostics
import Localization
import Persistence
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - Advanced

    var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.tabAdvanced, systemImage: "slider.horizontal.3", tint: .gray)
                SettingsCard {
                    if viewModel.customSources.isEmpty {
                        SettingsCardRow(minHeight: 40) {
                            Text(L10n.chooseFolderPanelMessage)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(Array(viewModel.customSources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { SettingsCardDivider() }
                            SettingsCardRow(minHeight: 34) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    Text(source.rootPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Button(role: .destructive) {
                                        viewModel.removeCustomSource(id: source.id)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("\(L10n.removeButton): \(source.rootPath)"))
                                }
                            }
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        HStack {
                            Spacer()
                            Button {
                                addFolder()
                            } label: {
                                Label(L10n.addFolderButton, systemImage: "plus.circle.fill")
                            }
                            .controlSize(.small)
                        }
                    }
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.layoutBackupHeader, systemImage: "externaldrive", tint: .blue)
                    SettingsCard {
                        SettingsCardRow(minHeight: 44) {
                            HStack {
                                Button(L10n.layoutBackupExport) { exportLayoutBackup() }
                                Spacer()
                                Button(L10n.layoutBackupImport) { importLayoutBackup() }
                            }
                            .disabled(isHandlingLayoutBackup)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.diagnosticsHeader, systemImage: "stethoscope", tint: .purple)
                    SettingsCard {
                        SettingsCardRow(minHeight: 34) {
                            HStack {
                                Spacer()
                                Button {
                                    saveDiagnosticsReport()
                                } label: {
                                    Label(L10n.diagnosticsSaveReport, systemImage: "square.and.arrow.down")
                                }
                                .controlSize(.small)
                                .disabled(isExportingDiagnostics)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.contentHorizontalPadding)
            .padding(.top, Metrics.contentTopPadding)
            .padding(.bottom, Metrics.contentBottomPadding)
        }
    }

    /// Writes the log archive wherever the user chooses. Deliberately a save
    /// panel rather than a fixed location: the file is meant to be attached to
    /// something, so it should land where the user will look for it.

    private func exportLayoutBackup() {
        guard !isHandlingLayoutBackup, let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LaunchpadNative-layout.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            isHandlingLayoutBackup = true
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    isHandlingLayoutBackup = false
                }
                do { try await viewModel.exportLayoutBackup(to: url) }
                catch { showLayoutBackupError(error, on: window) }
            }
        }
    }

    private func importLayoutBackup() {
        guard !isHandlingLayoutBackup, let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.layoutBackupConfirm
            alert.informativeText = L10n.layoutBackupConfirmMessage
            alert.addButton(withTitle: L10n.layoutBackupImport)
            alert.addButton(withTitle: L10n.cancelButton)
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                isHandlingLayoutBackup = true
                Task { @MainActor in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        isHandlingLayoutBackup = false
                    }
                    do { try await viewModel.restoreLayoutBackup(from: url) }
                    catch { showLayoutBackupError(error, on: window) }
                }
            }
        }
    }

    private func showLayoutBackupError(_ error: Error, on window: NSWindow) {
        let alert = NSAlert(error: error)
        alert.messageText = L10n.layoutBackupFailed
        alert.beginSheetModal(for: window)
    }

    private func saveDiagnosticsReport() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LaunchpadNative-logs-\(formatter.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        Task { @MainActor in
            defer { isExportingDiagnostics = false }
            await exportDiagnostics(to: url)
        }
    }

    private func exportDiagnostics(to url: URL) async {
        do {
            let summary = try await DiagnosticsArchive.writeInBackground(to: url)
            DiagnosticsLog.settings.notice(
                "Exported logs: \(summary.dayCount, privacy: .public) day(s), \(summary.entryCount, privacy: .public) entries, \(summary.byteCount, privacy: .public) bytes"
            )
            // The point of the file is to hand it to someone, so end by showing
            // where it landed rather than leaving the user to find it.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            DiagnosticsLog.settings.error("Log export failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = L10n.diagnosticsSaveFailed
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.okButton)
            alert.runModal()
        }
    }
}
