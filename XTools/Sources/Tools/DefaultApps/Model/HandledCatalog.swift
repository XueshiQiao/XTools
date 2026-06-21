import Foundation
import UniformTypeIdentifiers

/// A curated catalog entry, before its handlers are resolved: the LaunchServices
/// identifier plus how to present it. Resolved into a `HandledItem` by the scanner.
struct CatalogEntry {
    let kind: HandledItemKind
    let identifier: String      // UTI string, or bare URL scheme
    let labelKey: String        // L() key for the display label
    let symbol: String          // SF Symbol for the row tile
}

/// The fixed, hand-picked list of common file types and URL schemes XTools lets
/// you manage. Kept small and recognizable on purpose — this is a quick "who
/// opens my files" panel, not an exhaustive UTI browser.
///
/// File-type identifiers are derived from `UTType` so we always pass a real,
/// system-known UTI string to LaunchServices. A couple of types (Markdown) have
/// no system-declared `UTType` constant, so we resolve them by filename
/// extension and fall back to a literal UTI string if the lookup is nil.
enum HandledCatalog {

    /// Resolve a UTType to its identifier; nil if the type isn't known to this OS.
    private static func uti(_ type: UTType?) -> String? { type?.identifier }

    /// Markdown has no first-class `UTType` constant. Prefer the system's UTI for
    /// the ".md" extension (usually `net.daringfireball.markdown`), falling back
    /// to that literal string so the row still works on systems that don't map it.
    private static var markdownUTI: String {
        uti(UTType(filenameExtension: "md")) ?? "net.daringfireball.markdown"
    }

    /// CSV: prefer the system `commaSeparatedText` UTI; fall back to the ".csv"
    /// extension lookup, then the literal public UTI.
    private static var csvUTI: String {
        uti(.commaSeparatedText) ?? uti(UTType(filenameExtension: "csv")) ?? "public.comma-separated-values-text"
    }

    /// File types, in display order. Each builds on a real UTType where possible.
    static var fileTypes: [CatalogEntry] {
        var entries: [(String, String, String)] = []   // (utiOrNil-resolved, labelKey, symbol)

        func add(_ uti: String?, _ labelKey: String, _ symbol: String) {
            if let uti { entries.append((uti, labelKey, symbol)) }
        }

        add(uti(.plainText),      "defaultapps.type.plainText",  "doc.plaintext")
        add(uti(.rtf),            "defaultapps.type.rtf",        "doc.richtext")
        add(uti(.html),           "defaultapps.type.html",       "globe")
        add(markdownUTI,          "defaultapps.type.markdown",   "text.alignleft")
        add(uti(.json),           "defaultapps.type.json",       "curlybraces")
        add(uti(.xml),            "defaultapps.type.xml",        "chevron.left.forwardslash.chevron.right")
        add(csvUTI,               "defaultapps.type.csv",        "tablecells")
        add(uti(.propertyList),   "defaultapps.type.plist",      "list.bullet.rectangle")
        add(uti(.swiftSource),    "defaultapps.type.swift",      "swift")
        add(uti(.shellScript),    "defaultapps.type.shell",      "terminal")
        add(uti(.pdf),            "defaultapps.type.pdf",        "doc.richtext.fill")
        add(uti(.png),            "defaultapps.type.png",        "photo")
        add(uti(.jpeg),           "defaultapps.type.jpeg",       "photo.fill")
        add(uti(.zip),            "defaultapps.type.zip",        "doc.zipper")
        add(uti(.mpeg4Movie),     "defaultapps.type.mp4",        "film")
        add(uti(.mp3),            "defaultapps.type.mp3",        "music.note")

        return entries.map { CatalogEntry(kind: .contentType, identifier: $0.0, labelKey: $0.1, symbol: $0.2) }
    }

    /// URL schemes, in display order. Identifiers are bare scheme names (no "://").
    static var urlSchemes: [CatalogEntry] {
        [
            ("http",   "defaultapps.scheme.http",   "globe"),
            ("https",  "defaultapps.scheme.https",  "lock.fill"),
            ("mailto", "defaultapps.scheme.mailto", "envelope.fill"),
            ("tel",    "defaultapps.scheme.tel",    "phone.fill"),
            ("ftp",    "defaultapps.scheme.ftp",    "arrow.up.arrow.down"),
        ].map { CatalogEntry(kind: .urlScheme, identifier: $0.0, labelKey: $0.1, symbol: $0.2) }
    }

    /// Find the catalog entry backing a resolved item (matched on kind + identifier),
    /// so a single item can be re-resolved after a change.
    static func entry(for item: HandledItem) -> CatalogEntry? {
        let pool = item.kind == .contentType ? fileTypes : urlSchemes
        return pool.first { $0.identifier == item.identifier }
    }
}
