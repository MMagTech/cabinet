import SwiftUI

/// Every bundled layout, one tap into editing it.
struct EditorRootView: View {
    @State private var names = EditableLayout.allNames()
    @State private var opening: EditableLayout?
    @State private var showsCheatSheet = false

    var body: some View {
        NavigationStack {
            List(names, id: \.self) { name in
                Button {
                    if let layout = EditableLayout.load(name) {
                        opening = layout
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(.body, design: .monospaced))
                            if let title = LayoutName.title(for: name) {
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if WorkingCopy.isReady(name) {
                            Label("ready", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                        } else if WorkingCopy.isEdited(name) {
                            Label("edited", systemImage: "pencil.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing) {
                    if WorkingCopy.isEdited(name) {
                        Button("Discard edits", role: .destructive) {
                            WorkingCopy.discard(name)
                            names = EditableLayout.allNames()
                        }
                    }
                }
            }
            .navigationTitle("Layouts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsCheatSheet = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .onAppear {
                names = EditableLayout.allNames()
                WorkingCopy.sweepStaleCopies(bundled: names)
            }
        }
        .fullScreenCover(item: $opening) { layout in
            LayoutEditorView(layout: layout)
        }
        // A fullScreenCover dismissing does not itself re-trigger onAppear,
        // and edited/ready status is read straight off disk per row rather
        // than held in state, so nothing tells the list to look again unless
        // this does it explicitly.
        .onChange(of: opening == nil) { _, isNil in
            if isNil { names = EditableLayout.allNames() }
        }
        .sheet(isPresented: $showsCheatSheet) {
            LayoutCheatSheet()
        }
    }
}

/// What each short file name actually is, one tap away from the list. The
/// list already carries the same text as a subtitle, this is here for
/// anyone who wants the whole set at a glance, or wants to see the platform
/// slugs a layout answers to without opening every file.
struct LayoutCheatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(LayoutName.all, id: \.file) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.file)
                            .font(.system(.callout, design: .monospaced, weight: .semibold))
                        Text(entry.title)
                            .font(.callout)
                    }
                    Text(entry.slugs)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("What's what")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension EditableLayout: Identifiable {
    var id: String { name }
}
