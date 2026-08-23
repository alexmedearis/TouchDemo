//
//  TraceCanvasView.swift
//  Touch Demo
//
//  A trace-the-letter canvas with two interchangeable touch-handling
//  implementations, so the multi-touch bug and its fix can be compared
//  side by side on the same drawing surface.
//

import SwiftUI
import UIKit

enum TouchMode: String, CaseIterable, Identifiable {
    case buggy = "Buggy"
    case fixed = "Fixed"

    var id: String { rawValue }

    var headline: String {
        switch self {
        case .buggy: "Single tracking slot, claimed by the first touch"
        case .fixed: "Per-touch tracking, claimed only by a touch on the letter"
        }
    }

    var instructions: String {
        switch self {
        case .buggy:
            "Rest a finger anywhere on the paper first, then trace the A with a second finger — nothing fills in. Now trace first and add a second finger afterwards — it keeps working."
        case .fixed:
            "Rest as many fingers as you like anywhere on the paper, then trace the A — it fills in every time. Fingers that don't start on the letter are ignored, and several traces can run at once."
        }
    }
}

final class TraceCanvasView: UIView {

    // MARK: - Configuration

    private let inkColor = UIColor(red: 0.29, green: 0.21, blue: 0.78, alpha: 1)
    private let guideColor = UIColor.systemGray5

    /// How far off the centreline a finger may stray and still count as tracing.
    private var tolerance: CGFloat { guideWidth * 0.5 + 26 }

    var mode: TouchMode = .buggy {
        didSet {
            guard oldValue != mode else { return }
            resetTouchState()
        }
    }

    /// Bumped by the SwiftUI layer to request a clear.
    var lastClearToken = 0

    // MARK: - The letter
    //
    // Each pen stroke of the letter is a polyline with an arc-length table, so
    // any point on it can be named by a single number: how far along it is,
    // from 0 at the start to 1 at the end.

    private struct LetterStroke {
        var points: [CGPoint]
        var cumulative: [CGFloat]

        var length: CGFloat { cumulative.last ?? 0 }

        func point(atFraction f: CGFloat) -> CGPoint {
            let target = f * length
            guard points.count > 1 else { return points.first ?? .zero }
            for i in 1..<points.count where cumulative[i] >= target {
                let span = cumulative[i] - cumulative[i - 1]
                let t = span > 0 ? (target - cumulative[i - 1]) / span : 0
                let a = points[i - 1], b = points[i]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            return points[points.count - 1]
        }

        /// The piece of this stroke between two fractions, as a polyline.
        func polyline(from lower: CGFloat, to upper: CGFloat) -> [CGPoint] {
            let lo = max(0, min(lower, upper)) * length
            let hi = min(length, max(lower, upper) * length)
            guard hi >= lo else { return [] }
            var result = [point(atFraction: length > 0 ? lo / length : 0)]
            for i in points.indices where cumulative[i] > lo && cumulative[i] < hi {
                result.append(points[i])
            }
            result.append(point(atFraction: length > 0 ? hi / length : 0))
            return result
        }

        /// Nearest point on this stroke to `p`, as a fraction plus its distance.
        func nearest(to p: CGPoint) -> (fraction: CGFloat, distance: CGFloat) {
            guard points.count > 1, length > 0 else {
                let only = points.first ?? .zero
                return (0, hypot(p.x - only.x, p.y - only.y))
            }
            var best = (fraction: CGFloat(0), distance: CGFloat.greatestFiniteMagnitude)
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                let dx = b.x - a.x, dy = b.y - a.y
                let squared = dx * dx + dy * dy
                let t = squared > 0
                    ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
                    : 0
                let closest = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                let distance = hypot(p.x - closest.x, p.y - closest.y)
                if distance < best.distance {
                    let along = cumulative[i - 1] + t * sqrt(squared)
                    best = (along / length, distance)
                }
            }
            return best
        }
    }

    private var letterStrokes: [LetterStroke] = []
    private var letterPath = UIBezierPath()
    private var guideWidth: CGFloat = 44

    // MARK: - Progress
    //
    // Coverage is kept as fractions of each stroke rather than screen points,
    // so it survives a layout change.

    private var coverage: [[ClosedRange<CGFloat>]] = []

    /// Where a finger was last seen on the letter, so the gap between two
    /// touch samples can be filled in rather than left as a hole.
    private struct Anchor {
        var strokeIndex: Int
        var fraction: CGFloat
    }

    private struct Trace {
        var last: Anchor?
    }

    // MARK: - Touch state (buggy path)

    // BUG 0: the root cause, and it is this declaration rather than any of the
    // code below. One slot, one touch. The moment a view stores "the" touch
    // instead of "the touches that matter", the order the fingers land in
    // starts deciding whether drawing works at all.
    private var activeTouchID: ObjectIdentifier?
    private var activeTrace = Trace()

    // MARK: - Touch state (fixed path)

    /// Every touch that started a trace, each with its own progress along the
    /// letter. The counterpart to BUG 0: capacity is not one, it is however
    /// many touches happen to be relevant, and identity comes from the touch
    /// rather than from arrival order.
    private var traceByTouch: [ObjectIdentifier: Trace] = [:]

    // MARK: - Debug overlay

    private var touchMarkers: [ObjectIdentifier: (point: CGPoint, tracked: Bool)] = [:]

    // MARK: - Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Off by default on UIView — without this, UIKit only ever delivers the
        // first touch and *neither* implementation below can see a second
        // finger. Worth knowing that this one missing line reproduces the whole
        // bug on its own, with no faulty-looking code anywhere to find. It is
        // set explicitly here so the two modes differ only in how they track
        // touches, never in which touches they are handed.
        isMultipleTouchEnabled = true
        backgroundColor = .systemBackground
        isOpaque = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildLetter()
        setNeedsDisplay()
    }

    func clear() {
        coverage = letterStrokes.map { _ in [] }
        resetTouchState()
    }

    private func resetTouchState() {
        activeTouchID = nil
        activeTrace = Trace()
        traceByTouch.removeAll()
        touchMarkers.removeAll()
        setNeedsDisplay()
    }

    // MARK: - Letter geometry

    private func rebuildLetter() {
        let box = bounds.insetBy(dx: bounds.width * 0.17, dy: bounds.height * 0.11)
        guard box.width > 0, box.height > 0 else { return }

        guideWidth = max(28, min(box.width, box.height) * 0.15)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y)
        }

        let outlines: [[CGPoint]] = [
            // Left diagonal up to the apex, then back down the right diagonal.
            [point(0.00, 1.00), point(0.50, 0.00), point(1.00, 1.00)],
            // Crossbar, sitting on the diagonals at 68% of the height.
            [point(0.16, 0.68), point(0.84, 0.68)],
        ]

        letterStrokes = outlines.map { points in
            var cumulative: [CGFloat] = [0]
            for i in 1..<points.count {
                let previous = points[i - 1], current = points[i]
                cumulative.append(cumulative[i - 1] + hypot(current.x - previous.x, current.y - previous.y))
            }
            return LetterStroke(points: points, cumulative: cumulative)
        }

        if coverage.count != letterStrokes.count {
            coverage = letterStrokes.map { _ in [] }
        }

        let path = UIBezierPath()
        for points in outlines {
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
        }
        letterPath = path
    }

    /// Finds the point on the letter a finger is over, if it is over one at all.
    /// `preferred` keeps a trace from hopping onto the other pen stroke where
    /// the crossbar meets a diagonal.
    private func locate(_ p: CGPoint, preferring preferred: Int?) -> Anchor? {
        var best: (index: Int, hit: (fraction: CGFloat, distance: CGFloat))?
        for (index, stroke) in letterStrokes.enumerated() {
            let hit = stroke.nearest(to: p)
            if best == nil || hit.distance < best!.hit.distance {
                best = (index, hit)
            }
        }
        guard let best, best.hit.distance <= tolerance else { return nil }

        if let preferred, preferred != best.index, letterStrokes.indices.contains(preferred) {
            let staying = letterStrokes[preferred].nearest(to: p)
            if staying.distance <= best.hit.distance + guideWidth * 0.25 {
                return Anchor(strokeIndex: preferred, fraction: staying.fraction)
            }
        }
        return Anchor(strokeIndex: best.index, fraction: best.hit.fraction)
    }

    /// Advances one finger's progress to a new location, filling in everything
    /// it passed over on the way.
    private func advance(_ trace: inout Trace, to p: CGPoint) {
        guard let anchor = locate(p, preferring: trace.last?.strokeIndex) else {
            // Wandered off the letter — drop the anchor so the stretch it skips
            // while away doesn't get filled in when it comes back.
            trace.last = nil
            return
        }
        if let previous = trace.last, previous.strokeIndex == anchor.strokeIndex {
            cover(anchor.strokeIndex, from: previous.fraction, to: anchor.fraction)
        } else {
            cover(anchor.strokeIndex, from: anchor.fraction, to: anchor.fraction)
        }
        trace.last = anchor
    }

    private func cover(_ strokeIndex: Int, from a: CGFloat, to b: CGFloat) {
        guard coverage.indices.contains(strokeIndex) else { return }
        var lower = min(a, b), upper = max(a, b)
        var merged: [ClosedRange<CGFloat>] = []
        for range in coverage[strokeIndex] {
            if range.lowerBound > upper || range.upperBound < lower {
                merged.append(range)
            } else {
                lower = min(lower, range.lowerBound)
                upper = max(upper, range.upperBound)
            }
        }
        merged.append(lower...upper)
        coverage[strokeIndex] = merged.sorted { $0.lowerBound < $1.lowerBound }
    }

    // MARK: - Rendering

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        guideColor.setStroke()
        letterPath.lineWidth = guideWidth
        letterPath.lineCapStyle = .round
        letterPath.lineJoinStyle = .round
        letterPath.stroke()

        // The covered parts are redrawn as the letter itself, at full width, so
        // a single pass down the middle completes that stretch of the letter.
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineWidth(guideWidth + 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (index, stroke) in letterStrokes.enumerated() {
            guard coverage.indices.contains(index) else { continue }
            for range in coverage[index] {
                let points = stroke.polyline(from: range.lowerBound, to: range.upperBound)
                guard !points.isEmpty else { continue }
                ctx.addLines(between: points.count == 1 ? [points[0], points[0]] : points)
                ctx.strokePath()
            }
        }

        drawTouchMarkers(in: ctx)
    }

    private func drawTouchMarkers(in ctx: CGContext) {
        let radius: CGFloat = 30
        for (_, marker) in touchMarkers {
            let color: UIColor = marker.tracked ? .systemGreen : .systemGray
            let rect = CGRect(
                x: marker.point.x - radius,
                y: marker.point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            ctx.setFillColor(color.withAlphaComponent(0.18).cgColor)
            ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(3)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch mode {
        case .buggy: buggyTouchesBegan(touches)
        case .fixed: fixedTouchesBegan(touches)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch mode {
        case .buggy: buggyTouchesMoved(touches, event: event)
        case .fixed: fixedTouchesMoved(touches, event: event)
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    // MARK: Buggy path
    //
    // A single `activeTouchID` slot, claimed by whichever touch arrives first
    // and never reconsidered. Grep this section for "BUG" to see the four
    // places that combine into the failure.
    //
    // Rest a finger, then trace — BROKEN:
    //   1. touchesBegan(resting)  -> slot is free, resting finger takes it.
    //                                It is nowhere near the letter, so it
    //                                fills nothing in. It just sits there
    //                                holding the slot.
    //   2. touchesBegan(tracing)  -> slot is taken. Dropped at BUG 1.
    //   3. touchesMoved(tracing)  -> not the slot holder. Dropped at BUG 3.
    //
    // Trace, then rest a finger — WORKS:
    //   1. touchesBegan(tracing)  -> slot is free, tracing finger takes it.
    //   2. touchesBegan(resting)  -> slot is taken. Dropped at BUG 1, which
    //                                this time is harmless: the finger being
    //                                turned away is the irrelevant one.
    //   3. touchesMoved(tracing)  -> it *is* the slot holder, so it draws.
    //
    // Same code, same two fingers, opposite outcome. Whenever a touch bug
    // reads as order-dependent, look for state shaped like this.
    //
    // Two other causes produce this identical signature in a real app:
    //
    //   * `isMultipleTouchEnabled` left at its default of false, so UIKit
    //     never delivers the second touch at all (see commonInit above).
    //   * A SwiftUI `DragGesture`, which models one drag and binds it to the
    //     first finger down.
    //
    // To tell them apart, log at the very top of touchesBegan, above every
    // guard. If the second finger produces no log, delivery is the problem;
    // if it logs and still nothing draws, the state machine is.

    private func buggyTouchesBegan(_ touches: Set<UITouch>) {
        for touch in touches {
            touchMarkers[ObjectIdentifier(touch)] = (touch.location(in: self), false)
        }

        // BUG 1: first come, first served — and never revisited. The resting
        // finger got here first, so the finger about to trace the letter is
        // turned away before anything has even looked at where it landed.
        // Relevance should be decided by *where* a touch begins, not by *when*.
        //
        // This guard is rarely written as bluntly as it is here. The usual
        // spellings look like ordinary defensiveness:
        //
        //     guard !isDrawing else { return }
        //     guard currentStroke == nil else { return }
        //     if startPoint != nil { return }
        guard activeTouchID == nil else { return }

        // BUG 2: `touches` is a Set, so `first` is whichever element it happens
        // to yield. When two fingers land inside the same event, which one gets
        // the slot is a coin flip — which is why bugs of this shape often look
        // intermittent before somebody works out the ordering rule.
        guard let touch = touches.first else { return }

        let id = ObjectIdentifier(touch)
        let location = touch.location(in: self)
        activeTouchID = id
        activeTrace = Trace()
        advance(&activeTrace, to: location)
        touchMarkers[id] = (location, true)
    }

    private func buggyTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            touchMarkers[id] = (touch.location(in: self), id == activeTouchID)
        }

        // BUG 3: the far side of the trap. UIKit *does* deliver the tracing
        // finger's movement — it arrives in this very method, on time, with
        // correct coordinates — and this filter throws it on the floor because
        // some unrelated finger holds the slot. Nothing is broken at the OS
        // level. Every dropped touch here is self-inflicted.
        guard let activeTouchID else { return }
        guard let touch = touches.first(where: { ObjectIdentifier($0) == activeTouchID }) else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            advance(&activeTrace, to: sample.location(in: self))
        }
    }

    private func buggyTouchesEnded(_ touches: Set<UITouch>) {
        // BUG 4: freeing the slot comes too late to help. Lift the resting
        // finger mid-trace and the slot opens, but the tracing finger already
        // had its touchesBegan — and it will never get another one. It stays
        // ignored until it is lifted and put back down, which is why the bug
        // feels unrecoverable rather than merely delayed.
        guard let activeTouchID else { return }
        if touches.contains(where: { ObjectIdentifier($0) == activeTouchID }) {
            self.activeTouchID = nil
            activeTrace = Trace()
        }
    }

    // MARK: Fixed path
    //
    // Every touch is considered on its own. A touch is relevant only if it
    // begins on the letter; those get their own progress along it, keyed by the
    // touch itself, and are followed to the end. Touches that begin anywhere
    // else are ignored outright — they claim nothing, so any number of them can
    // be resting on the screen without affecting a trace.

    private func fixedTouchesBegan(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let location = touch.location(in: self)

            // FIX for BUG 1 and BUG 2: the whole set is walked, and each touch
            // is judged on where it landed rather than on when it arrived. A
            // finger that misses the letter simply fails this check and claims
            // nothing, so no number of resting fingers can block a trace.
            guard locate(location, preferring: nil) != nil else {
                touchMarkers[id] = (location, false)
                continue
            }

            var trace = Trace()
            advance(&trace, to: location)
            traceByTouch[id] = trace
            touchMarkers[id] = (location, true)
        }
    }

    private func fixedTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            touchMarkers[id] = (touch.location(in: self), traceByTouch[id] != nil)

            // FIX for BUG 3 and BUG 4: keyed by the touch's own identity, so
            // there is no shared slot to contend for. Traces advance
            // independently, and a touch that never registered is skipped
            // without disturbing the ones that did.
            guard var trace = traceByTouch[id] else { continue }
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                advance(&trace, to: sample.location(in: self))
            }
            traceByTouch[id] = trace
        }
    }

    private func fixedTouchesEnded(_ touches: Set<UITouch>) {
        for touch in touches {
            traceByTouch.removeValue(forKey: ObjectIdentifier(touch))
        }
    }

    // MARK: Shared

    private func endTouches(_ touches: Set<UITouch>) {
        switch mode {
        case .buggy: buggyTouchesEnded(touches)
        case .fixed: fixedTouchesEnded(touches)
        }
        for touch in touches {
            touchMarkers.removeValue(forKey: ObjectIdentifier(touch))
        }
        setNeedsDisplay()
    }
}

// MARK: - SwiftUI bridge

struct TraceCanvas: UIViewRepresentable {
    var mode: TouchMode
    var clearToken: Int

    func makeUIView(context: Context) -> TraceCanvasView {
        let view = TraceCanvasView()
        view.mode = mode
        view.lastClearToken = clearToken
        return view
    }

    func updateUIView(_ view: TraceCanvasView, context: Context) {
        view.mode = mode
        if view.lastClearToken != clearToken {
            view.lastClearToken = clearToken
            view.clear()
        }
    }
}
