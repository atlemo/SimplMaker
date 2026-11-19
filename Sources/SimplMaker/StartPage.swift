// The Start workspace: a page as big as the window, like the iPad's start screen. The app's name and tagline and the New Part and
// Open buttons on top; under them a panel with the ways to begin this part on the left and the recent parts on the right. The
// toolbar's workspace selector stays over it, so the page is one place among the others, not a dialog in front of them.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import CADCore
import SwiftUI

struct StartPage: View {
    @Bindable var model: DocumentModel
    let guide: TutorialGuide
    @Environment(\.newDocument) private var newDocument
    @AppStorage(Preferences.tutorialCompleted) private var tutorialCompleted = false

    /// Nothing built yet: the page offers the first steps. Otherwise it also offers the way back to the part.
    private var isEmpty: Bool { model.document.features.isEmpty }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 820
            let short = proxy.size.height < 700
            VStack(spacing: wide ? (short ? DS.Spacing.space8 : DS.Spacing.space10 + DS.Spacing.space8) : DS.Spacing.space7) {
                header(wide: wide, short: short)
                panel(wide: wide)
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, wide ? DS.Spacing.space10 : DS.Spacing.space6)
            .padding(.top, wide ? (short ? DS.Spacing.space6 : DS.Spacing.space10) : DS.Spacing.space6)
            .padding(.bottom, DS.Spacing.space10)
        }
        .background { StartBackground() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start")
    }

    static var versionText: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(version)"
    }

    // MARK: Header

    @ViewBuilder private func header(wide: Bool, short: Bool) -> some View {
        if wide {
            HStack(alignment: .center, spacing: DS.Spacing.space10) {
                brand(size: short ? 46 : 60)
                Spacer(minLength: 0)
                actions.frame(width: 250)
            }
        } else {
            VStack(spacing: DS.Spacing.space7) {
                brand(size: 40)
                actions.frame(maxWidth: 340)
            }
        }
    }

    /// The icon with the name and version, and the tagline.
    private func brand(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: size * 0.4) {
            HStack(spacing: DS.Spacing.space5) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 0) {
                    Text("SimplMaker").font(.title3.weight(.semibold))
                    Text(Self.versionText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Draw it.")
                Text("Dimension it.")
                Text("Print it.").foregroundStyle(DS.brand)
            }
            .font(.system(size: size, weight: .heavy))
            .tracking(-size * 0.03)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }

    /// New Part and Open, with the way into the tutorial under them.
    private var actions: some View {
        VStack(spacing: DS.Spacing.space5) {
            VStack(spacing: DS.Spacing.space5) {
                Button { newDocument { CADFile() } } label: { Label("New Part", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { NSDocumentController.shared.openDocument(nil) } label: { Label("Open…", systemImage: "folder").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            Button { startTutorial() } label: {
                HStack(spacing: DS.Spacing.space2) {
                    Text(tutorialCompleted ? "Done it before?" : "New here?").foregroundStyle(.secondary)
                    Text(tutorialCompleted ? "Do the tutorial again" : "Take the tutorial").foregroundStyle(DS.brand)
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Panel

    /// One block, rounded at its outside corners only: the ways to begin on white, the recent parts on white at 30 %, so the two read as
    /// parts of the same thing.
    private func panel(wide: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.window + DS.Spacing.space5, style: .continuous)
        let white = begin.frame(maxWidth: wide ? 380 : .infinity, maxHeight: .infinity).background(DS.windowBackground)
        let faded = recents.frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.windowBackground.opacity(0.3))
        return Group {
            if wide {
                HStack(spacing: 0) { white; faded }
            } else {
                VStack(spacing: 0) { white; faded }
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(shape)
    }

    /// The ways to begin this part (or to go on with it).
    private var begin: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space3) {
            Text(isEmpty ? "Begin this part" : "This part")
                .font(.headline)
                .padding(.horizontal, DS.Spacing.space4)
                .padding(.bottom, DS.Spacing.space2)
            if !isEmpty {
                StartAction(title: "Go on modelling", subtitle: "Back to the part in Design.", systemImage: "arrow.right.circle") {
                    model.setWorkspace(.design)
                }
            }
            StartAction(title: "Sketch", subtitle: "Draw a shape on a plane, then extrude it.", systemImage: "pencil.and.outline") {
                model.startSketch()
            }
            StartAction(title: "Box", subtitle: "A ready-made block to change from there.", systemImage: "cube") {
                model.run(.box)
            }
            StartAction(title: "Cylinder", subtitle: "A round block: a peg, a tube, a wheel.", systemImage: "cylinder") {
                model.run(.cylinder)
            }
            StartAction(title: "Open the demo part", subtitle: "A plate with a hole, fillets and a chamfer.", systemImage: "cube.transparent") {
                newDocument { CADFile(document: .demo()) }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.space5)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent parts")
                .font(.headline)
                .padding(.horizontal, DS.Spacing.space5 + DS.Spacing.space3)
                .padding(.top, DS.Spacing.space5)
            RecentPartsList()
        }
    }

    /// The tutorial makes a desk organizer: here when this part is still empty, otherwise in a part of its own.
    private func startTutorial() {
        if isEmpty {
            model.setWorkspace(.design)
            guide.start()
        } else {
            newDocument { CADFile(tutorial: true) }
        }
    }
}

/// The start page's backdrop: the grouped grey with a soft brand-orange glow in the top right corner and a warmer blush in the
/// bottom left, as on the iPad.
struct StartBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let longest = max(proxy.size.width, proxy.size.height)
            ZStack {
                DS.underPageBackground
                RadialGradient(colors: [DS.brand.opacity(0.22), DS.brand.opacity(0)], center: .topTrailing, startRadius: 0, endRadius: longest * 0.7)
                RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.55).opacity(0.14), .clear], center: .bottomLeading, startRadius: 0, endRadius: longest * 0.55)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
