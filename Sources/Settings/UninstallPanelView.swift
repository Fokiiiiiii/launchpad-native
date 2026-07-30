import AppKit
import Localization
import SwiftUI

/// Floating panel shown from the grid's "Uninstall…" context menu item.
/// Adapted directly from the user-supplied "Tessera" design reference's
/// `UninstallSheet` (`Dialogs.swift`) — same header (icon/name/total size),
/// same collapsible-group-with-checkbox layout, same per-row "show in
/// Finder" magnifying-glass button and monospaced path text — wired to
/// this app's real `UninstallPanelViewModel` data instead of the
/// reference's placeholder `UninstallItem`/`UninstallGroup` model.
///
/// Two deliberate departures from the reference, both safety-motivated and
/// already present in this project before this pass: "Move to Trash" has
/// no `.keyboardShortcut(.defaultAction)` (the reference's own button does)
/// so an accidental Return keypress can never trigger a destructive
/// action, and it's tinted red rather than the reference's default accent
/// color to visually set a destructive action apart from "Cancel."
struct UninstallPanelView: View {
    @ObservedObject var viewModel: UninstallPanelViewModel
    let appIcon: NSImage?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var expandedSections: Set<UninstallPanelViewModel.SectionKind> = Set(UninstallPanelViewModel.SectionKind.allCases)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(UninstallPanelViewModel.SectionKind.allCases, id: \.self) { kind in
                            if let rows = viewModel.rowsBySection[kind], !rows.isEmpty {
                                sectionView(kind: kind, rows: rows)
                            }
                        }
                    }
                }
                .frame(maxHeight: 296)
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
        HStack(spacing: 14) {
            Image(nsImage: appIcon ?? NSImage())
                .resizable()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.record.displayName)
                    .font(.system(size: 15.5, weight: .semibold))
                if viewModel.isComputingSizes {
                    Text(L10n.uninstallComputingSizesLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.totalSizeText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        // Leading trailing padding matches PanelCloseButton's own inset so
        // the app name never sits underneath it.
        .padding(.init(top: 20, leading: 20, bottom: 18, trailing: 44))
    }

    private func sectionView(kind: UninstallPanelViewModel.SectionKind, rows: [UninstallPanelViewModel.Row]) -> some View {
        let selectableRows = rows.filter { !$0.isDisabled }
        let isExpanded = expandedSections.contains(kind)
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                Toggle(isOn: Binding(
                    get: { !selectableRows.isEmpty && selectableRows.allSatisfy(\.isChecked) },
                    set: { newValue in
                        for row in selectableRows { viewModel.setChecked(newValue, rowID: row.id) }
                    }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(selectableRows.isEmpty)
                Label(sectionTitle(kind), systemImage: sectionSymbol(kind))
                    .font(.system(size: 13))
                Spacer()
                Button {
                    if isExpanded { expandedSections.remove(kind) } else { expandedSections.insert(kind) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)

            if isExpanded {
                ForEach(rows) { row in
                    Divider().padding(.leading, 50)
                    rowView(row)
                }
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.90), value: isExpanded)
    }

    private func rowView(_ row: UninstallPanelViewModel.Row) -> some View {
        HStack(spacing: 11) {
            Toggle(isOn: Binding(
                get: { row.isChecked },
                set: { viewModel.setChecked($0, rowID: row.id) }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(row.isDisabled)

            if row.removalItem.path == viewModel.record.bundleURL, let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.removalItem.path.lastPathComponent)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(row.removalItem.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isDisabled {
                    Text(L10n.uninstallNeedsPermissionNotice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if let size = row.sizeInBytes {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([row.removalItem.path])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 50)
        .padding(.trailing, 22)
        .padding(.vertical, 8)
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
            // accidental Return keypress must never trigger a Trash move,
            // unlike the reference's own button (see this type's doc
            // comment on why this diverges from it intentionally).
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
