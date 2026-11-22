// The Start workspace: a page as big as the window, like the iPad's start screen. The app's icon and name and the New Part and
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

    /// How far past the block the shadow's mask reaches.
    private static let shadowBleed: CGFloat = 120

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
            .padding(.top, (wide ? (short ? DS.Spacing.space6 : DS.Spacing.space10) : DS.Spacing.space6))
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
                brand(icon: short ? 76 : 96)
                Spacer(minLength: 0)
                actions(horizontal: true)
            }
        } else {
            VStack(spacing: DS.Spacing.space7) {
                brand(icon: 72)
                actions(horizontal: false).frame(maxWidth: 360)
            }
        }
    }

    /// The icon, big, with the name and the version beside it.
    private func brand(icon: CGFloat) -> some View {
        HStack(spacing: DS.Spacing.space6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: icon, height: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text("SimplMaker")
                    .font(.system(size: icon * 0.42, weight: .bold))
                    .tracking(-0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.versionText).font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    /// New Part and Open, big and side by side, with the way into the tutorial under them.
    private func actions(horizontal: Bool) -> some View {
        VStack(alignment: horizontal ? .trailing : .center, spacing: DS.Spacing.space5) {
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: DS.Spacing.space4)) : AnyLayout(VStackLayout(spacing: DS.Spacing.space4))
            layout {
                Button { newPart() } label: { Label("New Part", systemImage: "plus") }
                    .buttonStyle(StartButtonStyle(prominent: true))
                Button { NSDocumentController.shared.openDocument(nil) } label: { Label("Open…", systemImage: "folder") }
                    .buttonStyle(StartButtonStyle(prominent: false))
            }
            // Only until the tutorial has been done once: after that the start page has nothing to say about it (it stays in the Help menu).
            if !tutorialCompleted {
                Button { startTutorial() } label: {
                    HStack(spacing: DS.Spacing.space2) {
                        Text("New here?").foregroundStyle(.secondary)
                        Text("Take the tutorial").foregroundStyle(DS.brand)
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Panel

    /// One block, rounded at its outside corners only: the ways to begin on white, the recent parts on white at 50 %, so the two read as
    /// parts of the same thing.
    private func panel(wide: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.window + DS.Spacing.space5, style: .continuous)
        let white = begin.frame(maxWidth: wide ? 380 : .infinity, maxHeight: .infinity).background(DS.windowBackground)
        let faded = recents.frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.windowBackground.opacity(0.5))
        return Group {
            if wide {
                HStack(spacing: 0) { white; faded }
            } else {
                VStack(spacing: 0) { white; faded }
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        // The shadow is drawn behind the block only (not on its contents), and cut out of its inside, as on the iPad. The cut-out is one point
        // larger than the block: cut with the same outline, the antialiased rim of the black fill survives it as a dark, jagged fringe.
        .background {
            shape.fill(.black)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
                .mask { Rectangle().padding(-Self.shadowBleed).overlay { shape.inset(by: -1).blendMode(.destinationOut) }.compositingGroup() }
        }
    }

    /// The ways to begin this part (or to go on with it).
    private var begin: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space3) {
            Text(isEmpty ? "Make something new" : "This part")
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
            StartAction(title: "Open the demo part", subtitle: "A plate with a hole, fillets and a chamfer.", systemImage: "cube.transparent") {
                PartWindows.open { newDocument { CADFile(document: .demo()) } }
            }
            StartAction(title: "Watch the video tutorials", subtitle: "Short how-tos on the SimplMaker YouTube channel.", systemImage: "play.rectangle") {
                NSWorkspace.shared.open(URL(string: "https://www.youtube.com/@SimplMaker")!)
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

    /// New Part: this part itself, when it is only a Start page (a launcher does not stay behind), otherwise a new tab.
    private func newPart() {
        if isEmpty {
            model.setWorkspace(.design)
        } else {
            PartWindows.open { newDocument { CADFile(startsInDesign: true) } }
        }
    }

    /// The tutorial makes a desk organizer: here when this part is still empty, otherwise in a part of its own.
    private func startTutorial() {
        if isEmpty {
            model.setWorkspace(.design)
            guide.start()
        } else {
            PartWindows.open { newDocument { CADFile(tutorial: true) } }
        }
    }
}

/// The big buttons of the start page: New Part filled with the brand colour, Open on a quiet fill that shows in both appearances.
struct StartButtonStyle: ButtonStyle {
    let prominent: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.lg + 2, style: .continuous)
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, DS.Spacing.space8)
            .frame(minWidth: 170, minHeight: 52)
            .background {
                if prominent {
                    shape.fill(DS.brand.opacity(configuration.isPressed ? 0.8 : hovering ? 0.92 : 1))
                } else {
                    shape.fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.15 : 0.1))
                }
            }
            .overlay { if !prominent { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
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
