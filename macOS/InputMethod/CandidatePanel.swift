import AppKit
import SwiftUI
import HaiwangCore

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var source = ""
    @Published var cursor = 0
    @Published var preedit = ""
    @Published var candidates: [String] = []
    @Published var translation: String?
    @Published var isTranslating = false
    @Published var error: String?
    @Published var preferences = KeyboardPreferences()
    @Published var keyboard = InputMethodPreferences()
    @Published var highlightedIndex = 0
    @Published var engine = "设备端翻译"
    @Published var isPinned = false
    var choose: ((Int) -> Void)?
    var changeMarket: ((Market) -> Void)?
    var confirm: (() -> Void)?
    var openApp: (() -> Void)?
    var insertOriginal: (() -> Void)?
    var toggleTranslation: (() -> Void)?
    var toggleInputMode: (() -> Void)?
    var resetPosition: (() -> Void)?
}

/// Candidates occupy their text width rather than nine large fixed grid cells.
private struct CandidateFlowLayout: Layout {
    let spacing: CGFloat = 4

    private func arrangement(_ subviews: Subviews, width: CGFloat) -> ([CGRect], CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: width, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(subviews, width: max(1, proposal.width ?? 340)).1
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrangement(subviews, width: bounds.width).0) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct CandidateDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.toolTip = "拖动移动候选窗口，自动记住位置"
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("拖动出海王候选窗口")
        return view
    }
    func updateNSView(_ view: DragView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 90, height: proposal.height ?? 22)
    }
    final class DragView: NSView {
        private var dragStart: (pointer: NSPoint, origin: NSPoint)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStart = (screenLocation(of: event, in: window), window.frame.origin)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let dragStart else { return }
            let pointer = screenLocation(of: event, in: window)
            window.setFrameOrigin(NSPoint(x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
                                          y: dragStart.origin.y + pointer.y - dragStart.pointer.y))
        }
        private func screenLocation(of event: NSEvent, in window: NSWindow) -> NSPoint {
            // Quartz retains the pointer's screen position even if this passive
            // window has moved since the event was queued. Its Y axis is inverted.
            if let point = event.cgEvent?.location, let primary = NSScreen.screens.first {
                return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
            }
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }
    }
}

private struct CandidatePanelView: View {
    @ObservedObject var model: CandidatePanelModel
    private let ocean = Color(red: 0.04, green: 0.38, blue: 0.79)
    private var iconImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "InputMethodIcon", withExtension: "tiff") else { return nil }
        return NSImage(contentsOf: url)
    }
    private var translationHeight: CGFloat {
        let bounds = ((model.translation ?? "") as NSString).boundingRect(
            with: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)])
        return min(110, max(21, ceil(bounds.height) + 3))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    if let image = iconImage {
                        Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 14, height: 14).foregroundStyle(ocean)
                    }
                    Text("出海王").font(.system(size: 11, weight: .semibold))
                }
                .frame(height: 22)
                .overlay { CandidateDragArea() }
                .accessibilityIdentifier("candidate-window-drag-handle")
                Button(model.keyboard.inputMode == .pinyin ? "中" : "英") { model.toggleInputMode?() }
                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(ocean.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
                    .help("轻按 Shift 切换中文拼音／英文直输")
                    .accessibilityLabel(model.keyboard.inputMode == .pinyin ? "中文拼音，切换英文直输" : "英文直输，切换中文拼音")
                Spacer(minLength: 0)
                Button(model.keyboard.translationEnabled ? "翻译输入" : "普通输入") { model.toggleTranslation?() }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Control + Shift + T 切换普通／翻译输入")
                if model.keyboard.translationEnabled {
                    Menu {
                        ForEach(Market.allCases) { market in
                            Button("\(market.flag) \(market.name) · \(market.languageName)") { model.changeMarket?(market) }
                        }
                    } label: {
                        Text(model.preferences.market.languageName).font(.system(size: 11, weight: .medium))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                if model.isPinned {
                    Button { model.resetPosition?() } label: {
                        Image(systemName: "pin.slash").font(.system(size: 11))
                    }.buttonStyle(.plain).help("恢复候选窗口跟随光标")
                        .accessibilityLabel("恢复跟随光标")
                }
            }
            if !model.source.isEmpty || !model.preedit.isEmpty {
                let prefix = Text(String(model.source.prefix(model.cursor))).foregroundColor(.primary)
                let preedit = Text(model.preedit.isEmpty ? "▏" : model.preedit + "▏").foregroundColor(ocean)
                let suffix = Text(String(model.source.dropFirst(model.cursor))).foregroundColor(.primary)
                Text("\(prefix)\(preedit)\(suffix)")
                    .font(.system(size: 15)).lineLimit(model.keyboard.translationEnabled ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { CandidateDragArea() }
                    .accessibilityIdentifier("candidate-text-drag-handle")
            }
            if !model.candidates.isEmpty {
                CandidateFlowLayout {
                    ForEach(Array(model.candidates.prefix(9).enumerated()), id: \.offset) { index, value in
                        Button { model.choose?(index) } label: {
                            HStack(spacing: 3) {
                                Text("\(index + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(value).font(.system(size: 14, weight: index == model.highlightedIndex ? .semibold : .regular))
                                    .lineLimit(1)
                            }.padding(.horizontal, 4).padding(.vertical, 4)
                                .background(index == model.highlightedIndex ? ocean.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).help(value)
                    }
                }
            }
            if model.isTranslating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在翻译…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let result = model.translation {
                Divider()
                ScrollView {
                    Text(result).font(.system(size: 14, weight: .medium)).foregroundStyle(ocean)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: translationHeight)
                Button("确认上屏  ↵") { model.confirm?() }
                    .buttonStyle(.borderedProminent).tint(ocean).controlSize(.mini)
            }
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("打开出海王设置") { model.openApp?() }.font(.system(size: 11)).buttonStyle(.link)
            }
            HStack(spacing: 4) {
                if model.keyboard.translationEnabled {
                    if !model.source.isEmpty || !model.preedit.isEmpty {
                        Button("原文上屏") { model.insertOriginal?() }.buttonStyle(.link)
                    }
                    Text(model.translation == nil ? "↵ 翻译 · Esc 取消" : "↵ 上屏 · Esc 修改")
                    Spacer(minLength: 0)
                    Text(model.engine)
                } else {
                    Text("空格 / 数字选词")
                    Spacer(minLength: 0)
                    Text("Shift 中/英 · ⌃⇧T 翻译")
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)))
    }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Kept separate so screen bounds and growing pinned windows can be checked without UI input.
enum CandidatePanelGeometry {
    static func frame(size: NSSize, visible: NSRect, anchor: NSRect, pinned: CandidatePanelPosition?) -> NSRect {
        let margin: CGFloat = 4
        let fitted = NSSize(width: min(size.width, max(1, visible.width - margin * 2)),
                            height: min(size.height, max(1, visible.height - margin * 2)))
        let caret = anchor.isEmpty ? NSRect(x: visible.midX - fitted.width / 2, y: visible.midY, width: 1, height: 20) : anchor
        let requestedX = pinned.map { CGFloat($0.left) } ?? caret.minX
        let below = caret.minY - fitted.height - 6
        let requestedY = pinned.map { CGFloat($0.top) - fitted.height }
            ?? (below >= visible.minY + margin ? below : caret.maxY + 6)
        let x = max(visible.minX + margin, min(requestedX, visible.maxX - fitted.width - margin))
        let y = max(visible.minY + margin, min(requestedY, visible.maxY - fitted.height - margin))
        return NSRect(origin: NSPoint(x: x, y: y), size: fitted)
    }
}

@MainActor
final class CandidatePanel: NSObject, NSWindowDelegate {
    let model = CandidatePanelModel()
    private let window: NSPanel
    private let host: NSHostingView<CandidatePanelView>
    private let defaults: UserDefaults
    private var lastAnchor = NSRect.zero
    private var placingWindow = false
    private var programmaticFrame: NSRect?
    #if DEBUG
    var testingWindow: NSPanel { window }
    var presentsWindow = true
    #endif

    init(defaults: UserDefaults = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite) ?? .standard) {
        self.defaults = defaults
        host = NSHostingView(rootView: CandidatePanelView(model: model))
        window = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.title = "出海王候选窗口"
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovable = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        model.isPinned = CandidatePanelPosition.load(from: defaults) != nil
        model.resetPosition = { [weak self] in self?.resetPosition() }
    }

    func show(at rect: NSRect) {
        lastAnchor = rect
        host.layoutSubtreeIfNeeded()
        let pinned = CandidatePanelPosition.load(from: defaults)
        model.isPinned = pinned != nil
        let screen = pinned.flatMap { saved in
            NSScreen.screens.first { saved.displayID == ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
            ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: saved.left, y: saved.top)) }
        } ?? NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CandidatePanelGeometry.frame(size: host.fittingSize, visible: visible, anchor: rect, pinned: pinned)
        placingWindow = true
        window.setFrame(frame, display: true)
        programmaticFrame = window.frame
        placingWindow = false
        #if DEBUG
        if presentsWindow { window.orderFrontRegardless() }
        #else
        window.orderFrontRegardless()
        #endif
    }

    func windowDidMove(_ notification: Notification) {
        guard !placingWindow, window.isVisible else { return }
        if let expected = programmaticFrame,
           abs(window.frame.minX - expected.minX) < 0.5,
           abs(window.frame.maxY - expected.maxY) < 0.5 { return }
        let display = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        CandidatePanelPosition(left: window.frame.minX, top: window.frame.maxY, displayID: display).save(to: defaults)
        model.isPinned = true
    }

    func resetPosition() {
        CandidatePanelPosition.reset(in: defaults)
        model.isPinned = false
        if window.isVisible { show(at: lastAnchor) }
    }
    func hide() { window.orderOut(nil) }
}
