// The About panel: the standard macOS one, with credits naming what SimplMaker is built on and
// carrying the licence notices those components ask every copy of the app to include.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADKernel

@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        // The standard panel frames the credits with a border line; take it off.
        for window in NSApp.windows where window.isVisible {
            styleCredits(in: window.contentView)
        }
        NSApp.activate()
    }

    /// Border and side padding for the scroll view that holds our credits, so no other window is touched.
    private static func styleCredits(in view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let text = scroll.documentView as? NSTextView,
           text.string.hasPrefix("Acknowledgements") {
            scroll.borderType = .noBorder
            // Without the border the text runs to the panel edges; give it room at the sides.
            text.textContainerInset = NSSize(width: 20, height: 4)
        }
        for sub in view.subviews { styleCredits(in: sub) }
    }

    /// Something SimplMaker includes, credited by name, with its licence notice further down.
    private struct Component {
        var name: String
        var role: String
        var copyright: String
        var license: String
        var url: String?
        var notice: String
    }

    /// What the LGPL asks of an application that uses OCCT without being under it: tell the user the library
    /// is separate and replaceable, and where its source is.
    private static let occtReplacement = """
        SimplMaker uses Open CASCADE Technology as a separate library, libSimplOCCT.dylib, in the Frameworks \
        folder inside the SimplMaker application package. It is built, unmodified, from the Open CASCADE \
        Technology \(occtVersion) source (https://github.com/Open-Cascade-SAS/OCCT, tag V\(occtVersion.replacingOccurrences(of: ".", with: "_"))). \
        You may replace it with your own build of a compatible version of that library; macOS then requires \
        the application to be signed again (codesign --force --deep --sign - SimplMaker.app).
        """

    private static let components = [
        Component(name: "Open CASCADE Technology \(occtVersion)",
                  role: "The geometric modelling kernel.",
                  copyright: "Copyright © OPEN CASCADE SAS and contributors.",
                  license: "GNU LGPL 2.1 with the Open CASCADE exception.",
                  url: "https://dev.opencascade.org",
                  notice: occtReplacement + "\n\n" + LicenseTexts.occtException + "\n\nThe GNU LGPL 2.1 follows at the end."),
        Component(name: "DelaBella",
                  role: "Delaunay triangulation, part of OpenCASCADE's mesher.",
                  copyright: "Copyright © 2018 GUMIX – Marcin Sokalski.",
                  license: "MIT License.",
                  url: nil,
                  notice: LicenseTexts.delabella),
        Component(name: "flex",
                  role: "FlexLexer.h, used by OpenCASCADE's STEP reader.",
                  copyright: "Copyright © 1993 The Regents of the University of California.",
                  license: "BSD License.",
                  url: nil,
                  notice: LicenseTexts.flex),
        Component(name: "Sparkle",
                  role: "Software updates.",
                  copyright: "Copyright © 2006–2017 Andy Matuschak and contributors.",
                  license: "MIT License; bundled code under BSD and zlib-style licences.",
                  url: "https://sparkle-project.org",
                  notice: LicenseTexts.sparkle),
        Component(name: "Lucide",
                  role: "Line icons.",
                  copyright: "Copyright © Lucide Contributors; portions © Cole Bemis (Feather).",
                  license: "ISC License; Feather portions MIT License.",
                  url: "https://lucide.dev",
                  notice: LicenseTexts.lucide + "\n\n" + LicenseTexts.feather),
    ]

    /// Built the first time the panel opens: the licence texts are long.
    private static let credits: NSAttributedString = {
        let text = NSMutableAttributedString()
        let small = NSFont.systemFontSize(for: .small)

        func paragraph(_ alignment: NSTextAlignment, spacing: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.paragraphSpacing = spacing
            return style
        }
        let centered = paragraph(.center, spacing: 2), left = paragraph(.natural, spacing: 2)
        let body = paragraph(.natural, spacing: 6)

        func add(_ string: String, font: NSFont = .systemFont(ofSize: small), color: NSColor = .labelColor,
                 style: NSParagraphStyle = centered, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let link { attributes[.link] = URL(string: link) }
            text.append(NSAttributedString(string: string + "\n", attributes: attributes))
        }
        func heading(_ string: String, style: NSParagraphStyle = centered) {
            add("", style: style)
            add(string, font: .boldSystemFont(ofSize: small + 1), style: style)
        }

        // The copyright line is already under the credits, from Info.plist.
        add("Acknowledgements", font: .boldSystemFont(ofSize: small + 1))
        add("SimplMaker makes use of facilities provided by the Open CASCADE Technology software.",
            color: .secondaryLabelColor)
        for c in components {
            add("")
            add(c.name, font: .boldSystemFont(ofSize: small))
            for line in [c.role, c.copyright, c.license] { add(line, color: .secondaryLabelColor) }
            if let url = c.url { add(url.replacingOccurrences(of: "https://", with: ""), link: url) }
        }

        // The notices, then the long licence last.
        let notices = components.map { ($0.name, $0.notice) }
            + [("GNU Lesser General Public License 2.1 (Open CASCADE Technology)", LicenseTexts.lgpl21)]
        for (name, notice) in notices {
            heading(name, style: left)
            add(reflowed(notice), font: .systemFont(ofSize: small - 1), color: .secondaryLabelColor, style: body)
        }
        return text
    }()

    /// Hard-wrapped licence text as one line per paragraph, so it wraps to the narrow panel. A blank
    /// line ends a paragraph, and so does a line that starts a numbered item or a copyright notice.
    static func reflowed(_ text: String) -> String {
        var paragraphs: [String] = [], lines: [String] = []
        func endParagraph() {
            if !lines.isEmpty { paragraphs.append(lines.joined(separator: " ")) }
            lines = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("Copyright") || line.firstMatch(of: /^(\d+\.|\(?[a-z0-9]\))\s/) != nil {
                endParagraph()
            }
            if !line.isEmpty { lines.append(line) }
        }
        endParagraph()
        return paragraphs.joined(separator: "\n")
    }
}
