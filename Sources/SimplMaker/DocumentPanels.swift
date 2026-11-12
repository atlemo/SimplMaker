// The window's content: the viewport with the browser, inspector, timeline, status bar and tool panels floating over it. The Mac
// window and the iPad app share it; each brings its own viewport and the chrome that goes with it (the Mac's toolbar fade).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import SwiftUI

extension Color {
    /// The system's control background: the Mac's, or the iPad's secondary system background.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

/// A toolbar button's tooltip with its shortcut: "Show or hide the browser (⌃⌘S)".
func shortcutHelp(_ text: String, _ command: ShortcutCommand) -> String {
    Shortcuts.label(command).map { "\(text) (\($0))" } ?? text
}

/// The tutorial's card, placed where it floats: the bottom middle on the Mac, the bottom left on the iPad (with a margin from the
/// edge), clear of the side panels and above the status bar and the OK bar.
struct TutorialCardLayer: View {
    @Bindable var model: DocumentModel
    let guide: TutorialGuide

    private var alignment: Alignment { PanelTouch.panelToggleRoom == 0 ? .bottom : .bottomLeading }
    private var inset: CGFloat { PanelTouch.panelToggleRoom == 0 ? 0 : Panel.inset + 4 }

    var body: some View {
        // The empty layer around the card takes no touches: they go through to the view.
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: alignment) {
                TutorialCard(model: model, guide: guide)
                    .padding(.leading, (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0) + inset)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .padding(.bottom, (model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset)
                        + 2 * (DS.ControlHeight.large + Panel.inset) + Panel.inset)
            }
    }
}

struct DocumentPanels<Viewport: View, Chrome: View>: View {
    @Bindable var model: DocumentModel
    let guide: TutorialGuide
    let viewport: Viewport
    let chrome: Chrome

    /// Whether the tutorial's card is drawn here (the Mac) or by the caller, above everything else (the iPad).
    var cardHere = true
    func withoutTutorialCard() -> Self { var copy = self; copy.cardHere = false; return copy }

    /// The room the iPad's show/hide button for the inspector (or the Render view's own buttons) takes at the top right
    /// when the inspector is closed: what floats there goes left of it. None on the Mac.
    private var toggleRoom: CGFloat {
        PanelTouch.panelToggleRoom == 0 ? 0 : (model.renderView ? 176 : PanelTouch.panelToggleRoom + 10)
    }

    var body: some View {
        // The viewport fills the window, under the toolbar too; the browser and the inspector float
        // over it as glass panels, like the sidebars of current macOS apps. The toolbar has no
        // background until the pointer is over it, when one fades in.
        ZStack {
            viewport.ignoresSafeArea()

            chrome
            VStack(spacing: Panel.inset) {
            HStack(alignment: .top, spacing: 0) {
                if model.showSidebar {
                    Sidebar(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)  // empty: clicks go through to the viewport
                if model.showInspector {
                    InspectorView(model: model)
                        .padding(.top, PanelTouch.panelToggleRoom)
                        .floatingPanel(width: Panel.inspectorWidth)
                        .tutorialSpot("inspector", cornerRadius: DS.Radius.window, outset: 0, filled: false)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // With both panels closed the row holds only a Spacer, which has no height: without this the
            // stack would shrink to the timeline and float in the middle of the window.
            .frame(maxHeight: .infinity, alignment: .top)
            if model.showTimeline {
                TimelineBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
            .padding(Panel.inset)
            .animation(.easeOut(duration: DS.Duration.base), value: model.showTimeline)
            .animation(.easeOut(duration: DS.Duration.base), value: model.showSidebar)
            .animation(.easeOut(duration: DS.Duration.base), value: model.showInspector)
            if model.uiHidden {
                // The one control left: it brings the panels and toolbar back.
                VStack {
                    HStack {
                        Spacer()
                        Button { model.toggleUIHidden() } label: {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 38, height: 38)
                                .background(Color.platformControlBackground, in: Circle())
                                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help(shortcutHelp("Show the panels and toolbar again", .hideUI))
                        .accessibilityLabel("Show UI")
                    }
                    Spacer()
                }
                .padding(.trailing, 62)  // where the toolbar's button was: left of the Inspector button
                .padding(.top, 7)
                .ignoresSafeArea()  // the titlebar's room is still reserved at the top; the button sits in it
            }
            if model.showPalette {
                CommandPaletteView(model: model)
            }
        }
        // An empty part says how to begin, in the middle of the free space.
        .overlay {
            if model.document.features.isEmpty, model.sketchSession == nil, model.pendingTool == nil,
               !model.isPickingSketchPlane, !guide.isActive, !model.isImporting {
                StartCard(model: model, guide: guide)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .transition(.opacity)
            }
        }
        // A part that takes a while to open says what it is building, until the first model is on screen.
        .overlay {
            if model.result == nil, let progress = model.regenProgress {
                LoadingCard(progress: progress)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .transition(.opacity)
            }
        }
        // A big mesh being reduced and turned into a solid says so the same way.
        .overlay {
            if let progress = model.importProgress {
                LoadingCard(title: progress.title, fraction: progress.fraction, detail: progress.detail)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.regenProgress != nil)
        .animation(.easeOut(duration: DS.Duration.fast), value: model.importProgress != nil)
        // The tutorial's card floats at the bottom of the free space, above the status bar and the OK bar, where it
        // stays clear of what is built at the middle of the view and of the size fields that appear beside it.
        // On the iPad it sits at the bottom left, not the middle: the part and the grid's origin are in the middle of the view, and
        // the number pad comes up there.
        // (The iPad draws it itself, last of all, so that nothing floats above it: see `TutorialCardLayer`.)
        .overlay {
            if cardHere { TutorialCardLayer(model: model, guide: guide) }
        }
        // The status bar floats at the bottom, between the panels. The Render view is for looking at the part, so it goes there, unless
        // a tool or a sketch is waiting for something and the bar is where it says what.
        .overlay(alignment: .bottom) {
            if !model.renderView || model.pendingTool != nil || model.sketchSession != nil {
                StatusBar(model: model)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                    .padding(.bottom, model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.renderView)
        // The Appearance panel floats at the top, beside the inspector (and above the status bar, so its list can be reached; on the iPad
        // it keeps clear of the inspector's show/hide button, which floats at the corner while the inspector is closed).
        .overlay(alignment: .topTrailing) {
            if model.showAppearance, model.sketchSession == nil {
                AppearancePanel(model: model)
                    .padding(.top, Panel.inset)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset + toggleRoom)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.showAppearance)
        // The Measure tool's readout floats in the same corner.
        .overlay(alignment: .topTrailing) {
            if model.pendingTool == .measure, model.sketchSession == nil {
                MeasurePanel(model: model)
                    .padding(.top, Panel.inset)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset + toggleRoom)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.pendingTool == .measure)
        // A feature with no drag handle gets its OK and Cancel here, above the status bar.
        .overlay(alignment: .bottom) {
            FeatureDoneBar(model: model)
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                .padding(.bottom, (model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset) + DS.ControlHeight.large + Panel.inset)
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.featureWithoutHandle)
        // The sketch Mirror tool's choices (the axes, Delete, Cancel and OK) float in the same place.
        .overlay(alignment: .bottom) {
            SketchMirrorBar(model: model)
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                .padding(.bottom, (model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset) + DS.ControlHeight.large + Panel.inset)
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.sketchSession?.isMirroring == true)
        // The print preview's, Render and other options float at the top left of the view, above the status bar (a tall
        // panel covers it rather than hiding behind it, and scrolls when the window is shorter still).
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Panel.inset) {
                if model.printPreview, model.showPrintOptions, model.visualStyle.isShaded, model.sketchSession == nil {
                    PrintPreviewPanel(model: model)
                        .transition(.opacity)
                }
                if model.renderView, model.showRenderOptions, model.sketchSession == nil {
                    RenderPanel(model: model)
                        .transition(.opacity)
                }
                if model.explodeOn, model.showExplodeOptions {
                    ExplodePanel(model: model)
                        .transition(.opacity)
                }
                // The Section Analysis tool's options go under it.
                if model.section != nil, model.sketchSession == nil {
                    SectionPanel(model: model)
                        .transition(.opacity)
                }
            }
#if os(macOS)
            .padding(.top, Panel.inset)
            .padding(.bottom, Panel.inset)  // a tall panel covers the status bar rather than hiding behind it
#else
            // The browser's show/hide button floats in this corner while the browser is closed: the panels start under it.
            .padding(.top, model.showSidebar || model.renderView ? Panel.inset : Panel.inset + 44 + 8)
            // On the iPad the status bar stays readable: the panel ends above it (and scrolls if it is taller). Where the bar is not
            // shown (the Render view) the panel goes down to the bottom.
            .padding(.bottom, (model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset)
                              + (!model.renderView || model.pendingTool != nil || model.sketchSession != nil ? DS.ControlHeight.large + Panel.inset : 0))
#endif
            .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.showPrintOptions && model.printPreview)
        .animation(.easeOut(duration: DS.Duration.fast), value: model.showRenderOptions && model.renderView)
        .animation(.easeOut(duration: DS.Duration.fast), value: model.section != nil)
        .animation(.easeOut(duration: DS.Duration.fast), value: model.explodeOn && model.showExplodeOptions)
        // The cursor's prompt goes above everything, panels included.
        .overlay { CursorPrompt(model: model) }
#if os(iOS)
        // The timeline and status bar sit as low as the Mac's: the panels' gap to the screen's bottom edge, not the safe area under it.
        .ignoresSafeArea(.container, edges: .bottom)
#endif
    }
}
