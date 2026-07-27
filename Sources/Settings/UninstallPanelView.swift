import AppKit
import Localization
import SwiftUI

/// Floating panel shown from the grid's "Uninstall…" context menu item —
/// deliberately its own small window, not a Settings tab (the tab-nested
/// design Round 11 removed). Layout: app icon/name/total-size header, three
/// categorized sections (Application File/Cache/Preferences) each with a
/// per-item checkbox + byte size, and Cancel/Move to Trash at the bottom.
struct UninstallPanelView: View {
    @ObservedObject var viewModel: UninstallPanelViewModel
    let appIcon: NSImage?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(UninstallPanelViewModel.SectionKind.allCases, id: \.self) { kind in
                            if let rows = viewModel.rowsBySection[kind], !rows.isEmpty {
                                sectionView(kind: kind, rows: rows)
                            }
                        }
                    }
                    .padding(16)
                }
                Divider()
                footer
            }
            // Round 13 §A: the window's native titlebar/traffic-lights are
            // now fully hidden — this is the only remaining discoverable
            // way to close the panel beyond outside-click/Escape.
            PanelCloseButton(action: onCancel)
                .padding(12)
        }
        .background(.regularMaterial)
        .frame(width: 420, height: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: appIcon ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.record.displayName)
                    .font(.title3.weight(.semibold))
                if viewModel.isComputingSizes {
                    Text(L10n.uninstallComputingSizesLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.totalSizeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        // Leading trailing padding matches PanelCloseButton's own inset so
        // the app name never sits underneath it.
        .padding(.init(top: 20, leading: 20, bottom: 16, trailing: 44))
    }

    private func sectionView(kind: UninstallPanelViewModel.SectionKind, rows: [UninstallPanelViewModel.Row]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(sectionTitle(kind), systemImage: sectionSymbol(kind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
        }
    }

    private func rowView(_ row: UninstallPanelViewModel.Row) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { row.isChecked },
                set: { viewModel.setChecked($0, rowID: row.id) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.removalItem.path.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isDisabled {
                        Text(L10n.uninstallNeedsPermissionNotice)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(row.isDisabled)
            Spacer()
            if let size = row.sizeInBytes {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            let allRows = viewModel.rowsBySection.values.flatMap { $0 }
            let selectableRows = allRows.filter { !$0.isDisabled }
            Toggle(isOn: Binding(
                get: { !selectableRows.isEmpty && selectableRows.allSatisfy(\.isChecked) },
                set: { newValue in
                    for row in selectableRows { viewModel.setChecked(newValue, rowID: row.id) }
                }
            )) {
                Text(L10n.uninstallSelectAllLabel)
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button(L10n.uninstallCancelButton, action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(action: onConfirm) {
                Text(L10n.uninstallMoveToTrashButton)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            // Deliberately no `.keyboardShortcut(.defaultAction)` — an
            // accidental Return keypress must never trigger a Trash move.
        }
        .padding(16)
    }

    private func sectionTitle(_ kind: UninstallPanelViewModel.SectionKind) -> String {
        switch kind {
        case .applicationFile: L10n.uninstallSectionApplicationFile
        case .cache: L10n.uninstallSectionCache
        case .preferences: L10n.uninstallSectionPreferences
        }
    }

    private func sectionSymbol(_ kind: UninstallPanelViewModel.SectionKind) -> String {
        switch kind {
        case .applicationFile: "app.fill"
        case .cache: "externaldrive.fill"
        case .preferences: "gearshape.fill"
        }
    }
}
