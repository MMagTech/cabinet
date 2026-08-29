import SwiftUI

/// Settings > Native cores: one row per platform with a native
/// implementation and at least one option worth exposing, each pushing to
/// that platform's own options page. In Settings rather than in-game
/// because these are abstract toggles with nothing to visually compare,
/// per docs/scope-native-core-settings.md.
///
/// Listed by platform, not by core. Several platforms share one core
/// binary, and options set for one of them are not meaningful on the
/// others.
struct NativeCoresView: View {
    // Observed so the list redraws when the experimental switch flips
    // one screen up: options for a core the device is not offering
    // would be settings for a player that does not exist right now.
    @AppStorage(ExperimentalCores.key) private var experimentalCores = false

    private var platforms: [NativePlatform] {
        NativePlatform.allCases.filter {
            !NativeCoreOptions.options(for: $0).isEmpty
                && (!$0.isExperimental || experimentalCores)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(platforms, id: \.rawValue) { platform in
                    NavigationLink {
                        NativeCoreOptionsView(platform: platform)
                    } label: {
                        Text(platform.displayName)
                    }
                }
            } footer: {
                Text("Options apply to every game on this platform, not just the one you're currently playing.")
            }
        }
        .navigationTitle("Native cores")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeCoreOptionsView: View {
    let platform: NativePlatform
    @State private var values: [String: String] = [:]

    private var options: [NativeCoreOption] {
        NativeCoreOptions.options(for: platform)
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
                    // Virtual Boy's screen colour, shown rather than
                    // named. The Virtual Boy drew in black plus three
                    // brightnesses of one hue, and whether the dark end
                    // still reads is the whole question; a colour name
                    // does not answer it and neither does a swatch.
                    // Sits under the picker so choosing and seeing are
                    // the same screen.
                    if VirtualBoyPreview.canDraw(
                        values[option.key] ?? option.defaultValue
                    ) {
                        VirtualBoyPreview(
                            value: values[option.key] ?? option.defaultValue
                        )
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                    }
                } footer: {
                    if !option.detail.isEmpty { Text(option.detail) }
                }
            }
        }
        .navigationTitle(platform.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for option in options {
                values[option.key] = NativeCoreOptionsStore.value(option, for: platform)
            }
        }
    }

    private func binding(for option: NativeCoreOption) -> Binding<String> {
        Binding(
            get: { values[option.key] ?? option.defaultValue },
            set: { newValue in
                values[option.key] = newValue
                NativeCoreOptionsStore.setValue(newValue, for: option, platform: platform)
            }
        )
    }
}
