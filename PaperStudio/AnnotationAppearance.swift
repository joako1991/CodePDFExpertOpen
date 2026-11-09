// SPDX-License-Identifier: AGPL-3.0-or-later
import PDFKit

struct AnnotationAppearance: Equatable {
    let annotation: PDFAnnotation
    let color: UIColor
    let interior: UIColor?
    let font: UIFont?
    let fontColor: UIColor?
    let border: PDFBorder?
    let startLine: PDFLineStyle
    let endLine: PDFLineStyle
    private let appearance: Any?
    init(_ annotation: PDFAnnotation) {
        self.annotation = annotation; color = annotation.color; interior = annotation.interiorColor
        font = annotation.font; fontColor = annotation.fontColor; border = annotation.border?.copy() as? PDFBorder
        startLine = annotation.startLineStyle; endLine = annotation.endLineStyle
        appearance = annotation.value(forAnnotationKey: .appearanceDictionary)
    }
    func restore() {
        annotation.color = color; annotation.border = border?.copy() as? PDFBorder
        if ["Square","Circle","Line"].contains(annotation.type ?? "") { annotation.interiorColor = interior }
        if annotation.type == "FreeText" || annotation.type == "Widget" { annotation.font = font; annotation.fontColor = fontColor }
        if annotation.type == "Line" { annotation.startLineStyle = startLine; annotation.endLineStyle = endLine }
        restoreAppearanceStream()
    }
    func restoreAppearanceStream() {
        if let appearance { annotation.setValue(appearance, forAnnotationKey: .appearanceDictionary) }
        else { annotation.removeValue(forAnnotationKey: .appearanceDictionary) }
    }
    static func == (a: Self, b: Self) -> Bool {
        guard a.annotation === b.annotation, a.color == b.color, a.interior == b.interior,
              a.font == b.font, a.fontColor == b.fontColor else { return false }
        guard a.border?.lineWidth == b.border?.lineWidth, a.border?.style == b.border?.style else { return false }
        let aDash = a.border?.dashPattern as? [NSNumber], bDash = b.border?.dashPattern as? [NSNumber]
        return aDash == bDash && a.startLine == b.startLine && a.endLine == b.endLine
    }
}

extension PDFAnnotation {
    var supportsAppearanceEditing: Bool {
        ["FreeText", "Ink", "Square", "Circle", "Line", "Highlight", "Underline", "StrikeOut", "Squiggly"].contains(type ?? "")
    }
}
