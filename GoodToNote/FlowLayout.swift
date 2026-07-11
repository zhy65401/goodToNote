//
//  FlowLayout.swift
//  GoodToNote
//
//  GN-029 短信模版标注 UI 重做(token 点选高亮) — a minimal iOS 17 `Layout` that lays its
//  subviews out left-to-right and wraps to the next line when the next subview would overflow
//  the proposed width. Used by the rewritten SmsTemplateEditorView confirm screen to flow the
//  tappable token chips (one chip per selectable SmsToken) without a fixed grid.
//
//  Task-status connection: the confirm screen now shows the SMS as a wall of tappable word
//  chips the user highlights per category. Those chips are variable-width, so they need a
//  flow layout, not an HStack (which wouldn't wrap) or a LazyVGrid (fixed columns). This is a
//  pure UI component (no logic to unit-test) — verified by clean build, exercised on device.
//

import SwiftUI

/// Simple flow layout: place subviews left→right, wrap to a new line on horizontal overflow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x - bounds.minX + sz.width > maxW && x > bounds.minX {
                x = bounds.minX; y += lineH + spacing; lineH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
