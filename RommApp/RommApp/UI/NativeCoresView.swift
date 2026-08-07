import SwiftUI

/// Settings > Native cores: one row per core with a native implementation,
/// each pushing to that core's own options page. In Settings rather than
/// in-game because these are abstract toggles with nothing to visually
/// compare, per docs/scope-native-core-settings.md.
struct NativeCoresView: View {
    private let cores: [NativeCore] = [.fbneo, .beetleSaturn]

    var body: some View {
        List {
            Section {
                ForEach(cores, id: \.storageKey) { core in
                    NavigationLink {
                        NativeCoreOptionsView(core: core)
                    } label: {
                        Text(core.displayName)
                    }
                }
            } footer: {
                Text("Options apply to every game that core runs, not just the one you're currently playing.")
            }
        }
        .navigationTitle("Native cores")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeCoreOptionsView: View {
    let core: NativeCore
    @State private var values: [String: String] = [:]

    private var options: [NativeCoreOption] {
        NativeCoreOptions.options(for: core)
    }

    var body: some View {
        List {
            ForEach(options) { option in
                Section {
                    Picker(option.label, selection: binding(for: option)) {
                        ForEach(option.choices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                } footer: {
                    Text(option.detail)
                }
            }
        }
        .navigationTitle(core.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for option in options {
                values[option.key] = NativeCoreOptionsStore.value(option, for: core)
            }
        }
    }

    private func binding(for option: NativeCoreOption) -> Binding<String> {
        Binding(
            get: { values[option.key] ?? option.defaultValue },
            set: { newValue in
                values[option.key] = newValue
                NativeCoreOptionsStore.setValue(newValue, for: option, core: core)
            }
        )
    }
}
