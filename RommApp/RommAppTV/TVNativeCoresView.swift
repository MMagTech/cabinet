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
                        // A wrapping row, not an HStack: Virtual Boy's
                        // five glasses names overflow any single row at
                        // this type size, and an overflowing HStack
                        // compresses each Text into a one-letter column,
                        // which is how the pills came to read vertically.
                        WrapRow(spacing: 16) {
                            ForEach(option.choices, id: \.value) { choice in
                                choicePill(choice, for: option)
                            }
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
                .lineLimit(1)
                .fixedSize()
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

/// Lays children left to right, wrapping to a new line when the width
/// runs out, the flow every platform toolkit has and SwiftUI still does
/// not ship. Only what this screen needs: uniform spacing both ways.
private struct WrapRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
