import CoreGraphics
import Foundation

/// A glyph as filled shapes, one path per layer, ready to be placed in a template.
///
/// Unchecked because `CGPath` is not marked `Sendable`; every path here is an immutable
/// `CGPath` made by the outliner, and nothing keeps a mutable one.
public struct OutlinedSymbol: @unchecked Sendable {
    public let name: String
    /// Only the layers that drew something, in drawing order (wash, outline, touch).
    public let layers: [(SymbolLayer, CGPath)]
    /// Covers every layer, in box units; `.zero` when nothing is drawn.
    public var bounds: CGRect
}

/// Turns a drawing's strokes into the filled outlines a symbol template holds, and cuts a
/// marked touch out of the outline under it.
public enum SymbolGeometry {
    /// Bumped whenever the same source would outline to different geometry, so the lock
    /// can tell an asset written by an older outliner.
    public static let version = 1

    /// - Parameter strokeWidth: the family's stroke, in box units, for every element
    ///   that does not set its own; also the gap a knockout leaves (half of it each side).
    public static func outline(_ drawing: SymbolDrawing, strokeWidth: Double) -> OutlinedSymbol {
        var paths: [SymbolLayer: CGPath] = [:]
        for layer in SymbolLayer.allCases {
            guard let elements = drawing.layers[layer] else { continue }
            paths[layer] = union(elements.map { shape(of: $0, strokeWidth: strokeWidth) })
        }

        // A marked touch cuts the outline away under it, grown by half the stroke so a gap
        // shows round it; the wash lies under the outline and is never cut.
        let cutters = (drawing.layers[.touch] ?? []).filter(\.knockout).map { element in
            let shape = shape(of: element, strokeWidth: strokeWidth)
            let grown = shape.copy(
                strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
            return union([shape, grown])
        }
        if let outline = paths[.outline], !outline.isEmpty, !cutters.isEmpty {
            paths[.outline] = outline.subtracting(union(cutters), using: .winding)
        }

        let layers = SymbolLayer.allCases.compactMap { layer -> (SymbolLayer, CGPath)? in
            guard let path = paths[layer], !path.isEmpty, !path.boundingBoxOfPath.isEmpty else {
                return nil
            }
            return (layer, path)
        }
        let bounds = layers.reduce(CGRect.null) { $0.union($1.1.boundingBoxOfPath) }
        return OutlinedSymbol(name: drawing.name, layers: layers, bounds: bounds.isNull ? .zero : bounds)
    }

    /// What one element paints, as a filled shape: its fill, and its stroke outlined
    /// (dashed first, so each dash gets its own caps).
    static func shape(of element: SymbolElement, strokeWidth: Double) -> CGPath {
        let paint = element.paint
        var parts: [CGPath] = []
        if paint.fill { parts.append(element.path) }
        if paint.stroke {
            var line = element.path
            if !paint.dash.isEmpty {
                line = line.copy(dashingWithPhase: 0, lengths: paint.dash.map { CGFloat($0) })
            }
            let width = paint.strokeWidth ?? strokeWidth
            if width > 0 {
                parts.append(
                    line.copy(
                        strokingWithWidth: width, lineCap: paint.lineCap, lineJoin: paint.lineJoin,
                        miterLimit: 10))
            }
        }
        return union(parts)
    }

    /// The non-zero union of `paths`; also resolves a single path's own overlaps (a
    /// stroked polyline's joins), so the template gets clean contours.
    static func union(_ paths: [CGPath]) -> CGPath {
        paths.reduce(CGMutablePath() as CGPath) { $0.union($1, using: .winding) }
    }
}
