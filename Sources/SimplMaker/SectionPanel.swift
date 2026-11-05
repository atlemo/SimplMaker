// Section Analysis's panel (Mac). The cutting is in SectionAnalysis.swift, which the iPad app shares.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd
import SwiftUI

/// The Section Analysis tool's options, floating at the top left of the view while a cut is made.
struct SectionPanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270
    @State private var offsetText = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Section Analysis").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "End the section analysis") { model.endSection() }
            }
            if let cut = model.section {
                Toggle(isOn: Binding(get: { model.sectionOn }, set: { model.setSectionAnalysis($0) })) {
                    Text("Show the cut")
                }
                .toggleStyle(.switch)
                .help("Turn the cut on or off; the plane stays")
                LabeledContent("Cut at", value: cut.title)
                    .font(.callout)
                    .help("The plane the bodies are cut by")
                LabeledContent("Offset") {
                    TextField("Offset", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 110)
                        .focused($editing)
                        .arrowNudges($offsetText)
                        .onSubmit { commit() }
                        .help("How far the cut is from the plane: type a distance, or drag the arrow in the view")
                }
                .font(.callout)
                HStack {
                    Button("Flip Side") { model.flipSection() }
                        .help("Cut away the other side of the plane")
                    Button("Other Plane…") { model.chooseSectionPlane() }
                        .help("Click another plane, face, sketch or canvas to cut at")
                }
                .controlSize(.small)
                Text("Drag the arrow in the view to slide the cut in or out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
        .onAppear { offsetText = model.sectionOffsetText }
        .onChange(of: model.sectionOffsetText) { _, text in if !editing { offsetText = text } }
        .onChange(of: editing) { _, now in if !now { offsetText = model.sectionOffsetText } }
    }

    private func commit() {
        if !model.setSectionOffset(text: offsetText) {
            #if os(macOS)
            NSSound.beep()
            #else
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
        }
        offsetText = model.sectionOffsetText
    }
}
