//  About Cabinet, the Mac's own panel behind the app menu's About item.
//
//  A Mac About panel carries the name, the version, the credits and the
//  acknowledgements. The system panel Catalyst would show cannot hold
//  the licenses list, so this one is drawn by the app, with the same
//  glass the Settings sheet wears.

import SwiftUI

struct MacAboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text("Cabinet")
                            .font(.title2.bold())
                        Text(version)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Link(destination: URL(string: "https://github.com/rommapp/romm")!) {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } label: {
                            Text("RomM")
                        }
                    }
                    Link(destination: URL(string: "https://github.com/ilyas-hallak/romm-ios-app")!) {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } label: {
                            Text("romm-ios-app")
                        }
                    }
                } header: {
                    Text("Credits")
                } footer: {
                    Text("Cabinet talks to your RomM server, built by the RomM project and team. It was inspired by romm-ios-app, an earlier native client for RomM.")
                }
                .tvRow()

                Section {
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("Licenses", systemImage: "doc.text")
                    }
                } footer: {
                    Text("The software this app is built from, and the terms it ships under.")
                }
                .tvRow()
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("About Cabinet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
