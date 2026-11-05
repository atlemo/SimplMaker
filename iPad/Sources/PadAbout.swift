// About SimplMaker on the iPad: the licence of the app and the texts of the licences of what it includes.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PadAbout: View {
    private struct Entry: Identifiable { let id: String; let title: String; let text: String }

    private let source = "https://github.com/atlemo/SimplMaker"
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    private var entries: [Entry] {
        [Entry(id: "occt", title: "Open CASCADE Technology (LGPL 2.1 with the OCCT exception)",
               text: """
               The geometry kernel, built unmodified from the Open CASCADE Technology 8.0.1 source (https://github.com/Open-Cascade-SAS/OCCT, tag V8_0_1) with scripts/build-occt-ios.sh in the source repository, and linked statically into this app. \
               To use a changed version of it, rebuild the app from the source with your own build of the library and sign it yourself.

               \(LicenseTexts.occtException)

               The GNU LGPL 2.1 follows.

               \(LicenseTexts.lgpl21)
               """),
         Entry(id: "delabella", title: "DelaBella (MIT, part of Open CASCADE)", text: LicenseTexts.delabella),
         Entry(id: "flex", title: "FlexLexer.h (part of Open CASCADE)", text: LicenseTexts.flex),
         Entry(id: "icons", title: "Lucide and Feather icons (ISC, MIT)", text: LicenseTexts.lucide + "\n\n" + LicenseTexts.feather)]
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SimplMaker").font(.title2.weight(.semibold))
                    Text(version).foregroundStyle(.secondary)
                    Text("Copyright © 2026 Atle Mo. Free software under the GNU General Public License, version 3 or (at your option) any later version. The source code is at:")
                        .font(.callout)
                    Link(source, destination: URL(string: source)!)
                }
                .padding(.vertical, 4)
            }
            Section("Included software") {
                ForEach(entries) { e in
                    NavigationLink(e.title) {
                        ScrollView { Text(e.text).font(.system(size: 11, design: .monospaced)).padding().textSelection(.enabled) }
                            .navigationTitle(e.title).navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle("About SimplMaker")
        .navigationBarTitleDisplayMode(.inline)
    }
}
