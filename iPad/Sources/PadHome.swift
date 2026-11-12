// The start screen: the icon and the headline on the left, the New Part and Open buttons on the right, and under them a panel with
// the parts, switched between Recents and On My iPad by the system's segmented control. All controls are the system's own, in the
// brand orange. (The system's launch screen could not be laid out like this: it fixes its button in the middle and lets nothing
// of ours be touched, so the parts are listed here.)
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct PadHome: View {
    /// Opens a part in the editor; `tutorial` opens it with the tutorial's card showing.
    let open: (URL, _ tutorial: Bool) -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case recents = "Recents", device = "On My iPad"
        var id: Self { self }
    }

    @State private var parts = PadParts.shared
    @AppStorage("padHomeTab") private var tabName = Tab.recents.rawValue
    @State private var importing = false
    @State private var renaming: PadPart?
    @State private var newName = ""
    @State private var deleting: PadPart?
    @State private var failure: String?
    @Environment(\.scenePhase) private var scenePhase

    private var tab: Tab { Tab(rawValue: tabName) ?? .recents }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 720
            let short = proxy.size.height < 800
            VStack(spacing: wide ? (short ? 40 : 64) : 28) {
                header(wide: wide, short: short)
                panel
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, wide ? 40 : 20)
            .padding(.top, wide ? (short ? 40 : 72) : 28)
            .padding(.bottom, 24)
        }
        .background { PadWelcomeBackground() }
        .tint(DS.brand)
        .task { await parts.refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await parts.refresh() } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.simplMaker]) { result in
            if case .success(let url) = result { open(url, false) }
        }
        .alert("Rename Part", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let part = renaming else { return }
                do { try parts.rename(part.url, to: newName) } catch { failure = "“\(newName)” could not be used: \(error.localizedDescription)" }
                Task { await parts.refresh() }
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Part", role: .destructive) {
                if let part = deleting { do { try parts.delete(part) } catch { failure = error.localizedDescription } }
            }
        } message: { Text("This cannot be undone.") }
        .alert("Something went wrong", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    // MARK: Header

    @ViewBuilder private func header(wide: Bool, short: Bool) -> some View {
        if wide {
            HStack(alignment: .center, spacing: 40) {
                brand(size: short ? 46 : 60)
                Spacer(minLength: 0)
                actions.frame(width: 250)
            }
        } else {
            VStack(spacing: 20) {
                brand(size: 40)
                actions.frame(maxWidth: 340)
            }
        }
    }

    /// The icon with the name and version, and the headline.
    private func brand(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: size * 0.4) {
            HStack(spacing: 14) {
                PadWelcomeIcon(size: 56)
                VStack(alignment: .leading, spacing: 0) {
                    Text("SimplMaker").font(.title3.weight(.semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
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
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                Button { create(tutorial: false) } label: { Label("New Part", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { importing = true } label: { Label("Open…", systemImage: "folder").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            Button { create(tutorial: true) } label: {
                HStack(spacing: 5) {
                    Text("New here?").foregroundStyle(.secondary)
                    Text("Take the tutorial").foregroundStyle(DS.brand)
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
        }
    }

    private func create(tutorial: Bool) {
        do { open(try parts.createPart(named: tutorial ? "Tutorial" : "Untitled"), tutorial) }
        catch { failure = "The part could not be made: \(error.localizedDescription)" }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tabName) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            let list = tab == .recents ? parts.recents : parts.local
            if !parts.loaded {
                Spacer()
            } else if list.isEmpty {
                ContentUnavailableView(tab == .recents ? "No Recent Parts" : "No Parts on This iPad", systemImage: tab == .recents ? "clock" : "ipad",
                                       description: Text(tab == .recents ? "Parts you open show up here." : "Parts you make here are kept in this list."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 18)], spacing: 22) {
                        ForEach(list) { part in card(part) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        // The shadow is drawn behind the panel only (not on its contents), and cut out of its inside so the glass stays clear.
        .background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            shape.fill(.black)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
                .mask { Rectangle().padding(-120).overlay { shape.blendMode(.destinationOut) }.compositingGroup() }
        }
    }

    private func card(_ part: PadPart) -> some View {
        Button { open(part.url, false) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
                    if let image = part.thumbnail {
                        Image(uiImage: image).resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: "cube").font(.system(size: 34)).foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(part.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", systemImage: "folder") { open(part.url, false) }
            if part.isLocal {
                Button("Rename…", systemImage: "pencil") { newName = part.name; renaming = part }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    do { try parts.duplicate(part) } catch { failure = error.localizedDescription }
                    Task { await parts.refresh() }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = part }
            } else {
                Divider()
                Button("Remove from Recents", systemImage: "xmark") { parts.forget(part.url) }
            }
        }
    }
}

/// The start screen's backdrop: the system's grouped grey with a soft brand-orange glow in the top right corner and a warmer
/// blush in the bottom left, in place of a flat colour.
struct PadWelcomeBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let longest = max(proxy.size.width, proxy.size.height)
            ZStack {
                Color(.systemGroupedBackground)
                RadialGradient(colors: [DS.brand.opacity(0.22), DS.brand.opacity(0)], center: .topTrailing, startRadius: 0, endRadius: longest * 0.7)
                RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.55).opacity(0.14), .clear], center: .bottomLeading, startRadius: 0, endRadius: longest * 0.55)
            }
        }
        .ignoresSafeArea()
    }
}

/// The app icon.
struct PadWelcomeIcon: View {
    let size: CGFloat
    var body: some View {
        if let icon = UIImage(named: "WelcomeIcon") {
            Image(uiImage: icon).resizable().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }
}
