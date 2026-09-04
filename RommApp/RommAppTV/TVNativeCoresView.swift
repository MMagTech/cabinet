#if os(tvOS)
import SwiftUI

/// tvOS's sibling of iOS's `NativeCoresView`: one row per platform with a
/// native implementation and at least one option worth exposing, each
/// pushing to that platform's own options page, and each option in turn a
/// row carrying its current value that pushes to its own choices. Same
/// data source (`NativeCoreOptions`, `NativeCoreOptionsStore`) and the
/// same one-for-one intent iOS has.
///
/// The options were a wrapping row of choice pills until 2026-08-28. That
/// matched the library's Platforms switcher and read fine for two or three
/// short choices, but Virtual Boy has six glasses names as long as "Red
/// and electric cyan" and eight colours, and once a row wraps there is no
/// longer an obvious answer to what pressing right does. Wrapped pills
/// also put every choice on screen at equal weight, so the current one had
/// to be found rather than read.
///
/// A row carrying its value is what `TVSettingsView` already chose one
/// level up, for the reason it gives there: on a television every row of
/// scroll is focus travel, so a short list answered at a glance beats a
/// tall one. This page is now the same shape as the page that pushes to
/// it.
struct TVNativeCoresView: View {
    // Same filter as iOS's NativeCoresView, same reason: no settings
    // for a player this device is not offering.
    @AppStorage(ExperimentalCores.key) private var experimentalCores = false

    private var platforms: [NativePlatform] {
        NativePlatform.allCases.filter {
            !NativeCoreOptions.options(for: $0).isEmpty
                && (!$0.isExperimental || experimentalCores)
        }
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
            VStack(alignment: .leading, spacing: 16) {
                Text(platform.displayName)
                    .font(.largeTitle.weight(.bold))
                    .padding(.bottom, 8)

                ForEach(options) { option in
                    NavigationLink {
                        TVCoreOptionChoicesView(
                            option: option,
                            selected: values[option.key] ?? option.defaultValue
                        ) { picked in
                            values[option.key] = picked
                            NativeCoreOptionsStore.setValue(picked, for: option, platform: platform)
                        }
                    } label: {
                        row(for: option)
                    }
                    .buttonStyle(RowFocusStyle())
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

    /// The option's name, and the answer to it, on one line. The detail
    /// paragraph moves to the choices page: it is what someone wants while
    /// deciding, and only clutter once they have decided.
    private func row(for option: NativeCoreOption) -> some View {
        let current = values[option.key] ?? option.defaultValue
        let choice = option.choices.first { $0.value == current }
        return HStack(spacing: 20) {
            Text(option.label)
                .font(.title3)
            Spacer(minLength: 24)
            if let choice {
                ChoiceSwatch(value: choice.value)
                Text(choice.label)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One option's choices, one per row, with the current one ticked.
/// Picking writes through and pops, so the row that pushed here is
/// showing the new answer by the time it is back on screen.
///
/// Where a choice can be drawn, the drawing is large and sits beside the
/// list rather than inside each row. At ten feet a thumbnail in a row is
/// decoration: you cannot tell two anaglyph pairs apart at that size, and
/// telling them apart is the entire job. It follows focus, so running
/// down the list with the remote is the same gesture as trying each one,
/// and there is a picture big enough to hold a pair of glasses up to.
private struct TVCoreOptionChoicesView: View {
    let option: NativeCoreOption
    let selected: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    /// Focus, or the current answer before anything has taken focus.
    private var shown: String { focused ?? selected }

    private var drawable: Bool {
        option.choices.contains { VirtualBoyPreview.canDraw($0.value) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(option.label)
                        .font(.largeTitle.weight(.bold))
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                    ForEach(option.choices, id: \.value) { choice in
                        Button {
                            onPick(choice.value)
                            dismiss()
                        } label: {
                            HStack(spacing: 20) {
                                ChoiceSwatch(value: choice.value)
                                Text(choice.label)
                                    .font(.title3)
                                Spacer(minLength: 24)
                                Image(systemName: "checkmark")
                                    .font(.title3.weight(.semibold))
                                    .opacity(choice.value == selected ? 1 : 0)
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(RowFocusStyle())
                        .focused($focused, equals: choice.value)
                    }
                }
                .padding(.vertical, 50)
            }
            .frame(maxWidth: drawable ? 760 : .infinity, alignment: .leading)

            if drawable {
                VirtualBoyPreview(value: shown)
                    .frame(width: 620)
                    .padding(.top, 120)
                    .animation(.easeOut(duration: 0.15), value: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 80)
    }
}

/// Virtual Boy's option values are literally colour pairs, "black & red"
/// for a screen colour and "red & cyan" for a pair of glasses, so the dot
/// is read out of the data rather than from a table this file would have
/// to keep in step with the options. A screen colour is drawn as what it
/// is, the lit colour against the black the rest of the screen stays.
/// Anything that does not parse as a pair of known colours draws nothing,
/// which is every option on every other platform.
private struct ChoiceSwatch: View {
    let value: String

    private static let named: [String: Color] = [
        "black": .black,
        "white": .white,
        "red": .red,
        "blue": .blue,
        "cyan": .cyan,
        "electric cyan": Color(red: 0.45, green: 1.0, blue: 1.0),
        "green": .green,
        "magenta": Color(red: 1.0, green: 0.0, blue: 1.0),
        "yellow": .yellow,
    ]

    private var pair: (Color, Color)? {
        let parts = value.split(separator: "&").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard parts.count == 2,
              let first = Self.named[parts[0]],
              let second = Self.named[parts[1]] else { return nil }
        return (first, second)
    }

    var body: some View {
        if let pair {
            HStack(spacing: 0) {
                Rectangle().fill(pair.0)
                Rectangle().fill(pair.1)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            // Black is half of every screen colour, so the dot needs an
            // edge of its own or it reads as a gap on a dark background.
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        }
    }
}
#endif
