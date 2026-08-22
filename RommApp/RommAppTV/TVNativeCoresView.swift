#if os(tvOS)
import SwiftUI

/// tvOS's sibling of iOS's `NativeCoresView`: one row per platform with a
/// native implementation and at least one option worth exposing, each
/// pushing to that platform's own options page. Same data source
/// (`NativeCoreOptions`, `NativeCoreOptionsStore`) and the same one-for-one
/// intent iOS has, laid out as cards instead of a `List` for the reasons
/// `TVSettingsView` already gives, and each option as a row of glass
/// choice pills instead of a `Picker`, the same pattern the library's own
/// Platforms/Collections switcher already established, since most options
/// here are a handful of mutually exclusive choices, not an open list.
///
/// Starting as a one-for-one match with iOS on purpose: same platforms,
/// same options, same defaults. What tvOS actually needs may diverge from
/// this over time (see the roadmap memory this was built against), but
/// there is no reason to guess at a difference before real use turns one
/// up.
struct TVNativeCoresView: View {
    private var platforms: [NativePlatform] {
        NativePlatform.allCases.filter { !NativeCoreOptions.options(for: $0).isEmpty }
    }

    var body: some View {
        ScrollView {
            // No .navigationTitle: on tvOS it paints over content instead
            // of reserving space above it (TVLibraryView's own doc
            // comment already covers this), so the title is a plain view
            // in the scroll content instead, same pattern every other
            // tvOS screen in this app already uses.
            VStack(alignment: .leading, spacing: 16) {
                Text("Cores")
                    .font(.largeTitle.weight(.bold))
                Text("Options apply to every game on the platform.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                ForEach(platforms, id: \.rawValue) { platform in
                    NavigationLink {
                        TVNativeCoreOptionsView(platform: platform)
                    } label: {
                        HStack {
                            Text(platform.displayName)
                                .font(.title3)
                            Spacer(minLength: 24)
                            Image(systemName: "chevron.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(RowFocusStyle())
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
    }
}

private struct TVNativeCoreOptionsView: View {
    let platform: NativePlatform
    @State private var values: [String: String] = [:]

    private var options: [NativeCoreOption] {
        NativeCoreOptions.options(for: platform)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text(platform.displayName)
                    .font(.largeTitle.weight(.bold))
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label)
                                .font(.title3.weight(.semibold))
                            Text(option.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            ForEach(option.choices, id: \.value) { choice in
                                choicePill(choice, for: option)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
        .onAppear {
            for option in options {
                values[option.key] = NativeCoreOptionsStore.value(option, for: platform)
            }
        }
    }

    private func choicePill(_ choice: NativeCoreOption.Choice, for option: NativeCoreOption) -> some View {
        let selected = (values[option.key] ?? option.defaultValue) == choice.value
        return Button {
            values[option.key] = choice.value
            NativeCoreOptionsStore.setValue(choice.value, for: option, platform: platform)
        } label: {
            Text(choice.label)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background {
                    if #available(tvOS 26.0, *) {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(
                                selected ? .regular.tint(.white.opacity(0.35)) : .regular,
                                in: Capsule()
                            )
                    } else {
                        Capsule().fill(
                            selected
                                ? AnyShapeStyle(.white.opacity(0.18))
                                : AnyShapeStyle(.clear)
                        )
                    }
                }
        }
        .buttonStyle(TextFocusStyle())
    }
}
#endif
