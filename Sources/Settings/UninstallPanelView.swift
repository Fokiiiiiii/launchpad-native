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
        .frame(width: 420, height: 480)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: appIcon ?? NSImage())
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.record.displayName)
                    .font(.headline)
                if viewModel.isComputingSizes {
                    Text(L10n.uninstallComputingSizesLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.totalSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func sectionView(kind: UninstallPanelViewModel.SectionKind, rows: [UninstallPanelViewModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sectionTitle(kind))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                rowView(row)
            }
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
            Button(role: .destructive, action: onConfirm) {
                Text(L10n.uninstallMoveToTrashButton)
            }
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
}
