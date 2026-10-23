// LiteCalendar — kalender dua bulan untuk menu bar macOS
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)

import Cocoa
import EventKit
import ServiceManagement

let defaults = UserDefaults.standard
let idLocale = Locale(identifier: "id_ID")

// MARK: - Tanggal

/// Kalender yang dipakai seluruh aplikasi (hari pertama minggu bisa diatur di menu)
func appCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.locale = idLocale
    c.timeZone = .current
    let fw = defaults.integer(forKey: "firstWeekday") // 0 = ikuti sistem, 1 = Minggu, 2 = Senin
    c.firstWeekday = fw == 0 ? Calendar.current.firstWeekday : fw
    return c
}

extension Calendar {
    func startOfMonth(_ d: Date) -> Date { date(from: dateComponents([.year, .month], from: d)) ?? d }
    func adding(months n: Int, to d: Date) -> Date { date(byAdding: .month, value: n, to: d) ?? d }
    func adding(days n: Int, to d: Date) -> Date { date(byAdding: .day, value: n, to: d) ?? d }
}

func dateFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = idLocale
    f.dateFormat = format
    return f
}
let fmtMonth = dateFormatter("LLLL")
let fmtYear = dateFormatter("yyyy")
let fmtDayLong = dateFormatter("EEEE, d MMMM")
let fmtTime = dateFormatter("HH.mm")
let fmtBar = dateFormatter("EEE d MMM")

/// Bulan pertama (kiri) tampilan awal:
/// tanggal > 15 → bulan ini | bulan depan, tanggal ≤ 15 → bulan lalu | bulan ini
func defaultFirstMonth(_ now: Date = Date()) -> Date {
    let c = appCalendar()
    let m = c.startOfMonth(now)
    return c.component(.day, from: now) > 15 ? m : c.adding(months: -1, to: m)
}

// MARK: - Acara (EventKit: iCloud, Google, Exchange, dsb. yang terhubung di Mac ini)

final class EventSource {
    private(set) var store = EKEventStore()

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var hasAccess: Bool {
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }
    var canAsk: Bool { status == .notDetermined }

    var hiddenCalendars: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenCalendars") ?? []) }
        set { defaults.set(Array(newValue), forKey: "hiddenCalendars") }
    }

    var calendars: [EKCalendar] { hasAccess ? store.calendars(for: .event) : [] }

    /// Minta izin baca kalender; done(true) kalau diizinkan (dipanggil di main thread)
    func requestAccess(_ done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { ok, _ in
            DispatchQueue.main.async {
                if ok { self.store = EKEventStore() } // store baru supaya data langsung terbaca
                done(ok)
            }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToEvents(completion: finish) }
        else { store.requestAccess(to: .event, completion: finish) }
    }

    /// Acara per hari (kunci: awal hari) dalam rentang [from, to)
    func eventsByDay(from: Date, to: Date, cal: Calendar) -> [Date: [EKEvent]] {
        guard hasAccess else { return [:] }
        let hidden = hiddenCalendars
        let cals = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [:] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        var out: [Date: [EKEvent]] = [:]
        for e in store.events(matching: pred) {
            guard let start = e.startDate, let end = e.endDate else { continue }
            // acara beberapa hari dimasukkan ke setiap harinya
            var day = max(cal.startOfDay(for: start), from)
            repeat {
                out[day, default: []].append(e)
                day = cal.adding(days: 1, to: day)
            } while day < end && day < to
        }
        for (k, v) in out {
            out[k] = v.sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
        }
        return out
    }
}

/// Kalender hari libur (mis. "Hari Libur di Indonesia") → tanggalnya diberi warna merah
func isHoliday(_ e: EKEvent) -> Bool {
    let t = (e.calendar?.title ?? "").lowercased()
    return t.contains("libur") || t.contains("holiday")
}

// MARK: - Ikon menu bar

/// Ikon kalender kecil dengan angka tanggal di dalamnya (template → ikut warna menu bar)
func renderBarIcon(day: Int) -> NSImage {
    let size = NSSize(width: 18, height: 22)
    let img = NSImage(size: size, flipped: true) { _ in
        let body = NSRect(x: 1, y: 3.5, width: 16, height: 15)
        let path = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
        NSColor.black.setStroke()
        path.lineWidth = 1.3
        path.stroke()
        // pita atas kalender
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.black.setFill()
        NSRect(x: 0, y: 3, width: 18, height: 3.6).fill()
        NSGraphicsContext.restoreGraphicsState()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let s = "\(day)" as NSString
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let w = s.size(withAttributes: attr).width
        let h = font.ascender - font.descender
        s.draw(at: NSPoint(x: body.midX - w / 2, y: 6.6 + (11.9 - h) / 2), withAttributes: attr)
        return true
    }
    img.isTemplate = true
    return img
}

/// Titik kecil berwarna untuk menu daftar kalender
func colorDot(_ c: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
        c.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
}

func attrs(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
           align: NSTextAlignment = .left, mono: Bool = false) -> [NSAttributedString.Key: Any] {
    let ps = NSMutableParagraphStyle()
    ps.alignment = align
    ps.lineBreakMode = .byTruncatingTail
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    return [.font: font, .foregroundColor: color, .paragraphStyle: ps]
}

/// Gambar teks satu baris, rata tengah secara vertikal di dalam r
func drawText(_ s: String, in r: NSRect, _ a: [NSAttributedString.Key: Any]) {
    let font = a[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
    let h = ceil(font.ascender - font.descender + font.leading)
    (s as NSString).draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: a)
}

// MARK: - Tampilan satu bulan

final class MonthView: NSView {
    static let cellW: CGFloat = 34, cellH: CGFloat = 36, titleH: CGFloat = 30, weekH: CGFloat = 20
    static var size: NSSize { NSSize(width: cellW * 7, height: titleH + weekH + cellH * 6) }

    var month = Date()                      // hari pertama bulan ini
    var events: [Date: [EKEvent]] = [:]
    var selected: Date?
    var onSelect: ((Date) -> Void)?
    private var hover: Date?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// (kalender, kolom tanggal 1, jumlah hari)
    private func grid() -> (Calendar, Int, Int) {
        let c = appCalendar()
        let offset = (c.component(.weekday, from: month) - c.firstWeekday + 7) % 7
        let count = c.range(of: .day, in: .month, for: month)?.count ?? 30
        return (c, offset, count)
    }

    private func cellRect(_ idx: Int) -> NSRect {
        NSRect(x: CGFloat(idx % 7) * Self.cellW, y: Self.titleH + Self.weekH + CGFloat(idx / 7) * Self.cellH,
               width: Self.cellW, height: Self.cellH)
    }

    /// Tanggal di titik p; nil kalau bukan sel tanggal bulan ini
    private func date(at p: NSPoint) -> Date? {
        let (c, offset, count) = grid()
        let y = p.y - Self.titleH - Self.weekH
        guard y >= 0, p.x >= 0, p.x < Self.cellW * 7 else { return nil }
        let i = Int(y / Self.cellH) * 7 + Int(p.x / Self.cellW) - offset
        guard i >= 0, i < count else { return nil }
        return c.adding(days: i, to: month)
    }

    override func draw(_ dirtyRect: NSRect) {
        let (c, offset, count) = grid()
        let today = c.startOfDay(for: Date())

        // judul: "Oktober 2026" (tahun lebih redup)
        let title = NSMutableAttributedString(string: fmtMonth.string(from: month).capitalized,
                                              attributes: attrs(13, .semibold, .labelColor, align: .center))
        title.append(NSAttributedString(string: " " + fmtYear.string(from: month),
                                        attributes: attrs(13, .regular, .secondaryLabelColor, align: .center)))
        title.draw(in: NSRect(x: 0, y: 7, width: bounds.width, height: 18))

        // nama hari: Sen Sel Rab ... (Minggu merah)
        let names = c.shortStandaloneWeekdaySymbols
        for col in 0..<7 {
            let wd = (c.firstWeekday - 1 + col) % 7 // 0 = Minggu
            let color: NSColor = wd == 0 ? .systemRed.withAlphaComponent(0.75) : .tertiaryLabelColor
            drawText(names[wd], in: NSRect(x: CGFloat(col) * Self.cellW, y: Self.titleH, width: Self.cellW, height: Self.weekH),
                     attrs(10, .medium, color, align: .center))
        }

        for i in 0..<count {
            let r = cellRect(offset + i)
            let day = c.adding(days: i, to: month)
            let evs = events[day] ?? []
            let isToday = day == today, isSel = day == selected
            let circle = NSRect(x: r.midX - 13, y: r.minY + 2, width: 26, height: 26)

            if isToday {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else if isSel {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else if day == hover {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }

            let red = c.component(.weekday, from: day) == 1 || evs.contains(where: isHoliday)
            let color: NSColor = isToday ? .white : isSel ? .controlAccentColor : red ? .systemRed : .labelColor
            drawText("\(i + 1)", in: circle, attrs(12.5, isToday || isSel ? .semibold : .regular, color,
                                                   align: .center, mono: true))

            // titik acara: maksimal 3 warna kalender berbeda
            var colors: [NSColor] = []
            for e in evs where colors.count < 3 {
                let col = e.calendar?.color ?? .systemGray
                if !colors.contains(col) { colors.append(col) }
            }
            let dot: CGFloat = 4, gap: CGFloat = 2.5
            var x = r.midX - (CGFloat(colors.count) * dot + CGFloat(max(colors.count - 1, 0)) * gap) / 2
            for col in colors {
                col.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + 30, width: dot, height: dot)).fill()
                x += dot + gap
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let d = date(at: convert(event.locationInWindow, from: nil))
        if d != hover { hover = d; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if let d = date(at: convert(event.locationInWindow, from: nil)) { onSelect?(d) }
    }
}

// MARK: - Daftar acara hari terpilih

final class AgendaView: NSView {
    static let headerH: CGFloat = 28, rowH: CGFloat = 26, maxRows = 5
    static var height: CGFloat { headerH + rowH * CGFloat(maxRows) }

    enum Access { case granted, ask, denied }

    var day = Date()
    var isToday = false
    var items: [EKEvent] = []
    var access = Access.granted { didSet { updateButton() } }
    var onOpen: ((EKEvent?) -> Void)?   // klik baris acara (nil = "+N lainnya")
    var onAccess: (() -> Void)?         // tombol izin / pengaturan
    private var hoverRow: Int?
    private let button = NSButton(title: "", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(accessClicked)
        addSubview(button)
        updateButton()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateButton() {
        button.isHidden = access == .granted
        button.title = access == .ask ? "Izinkan akses Kalender" : "Buka Pengaturan Privasi"
        button.sizeToFit()
        button.setFrameOrigin(NSPoint(x: (bounds.width - button.frame.width) / 2, y: Self.headerH + 64))
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        updateButton()
    }
    @objc private func accessClicked() { onAccess?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Baris yang ditampilkan: kalau lebih dari maxRows, baris terakhir jadi "+N acara lainnya"
    private var shown: Int { items.count > Self.maxRows ? Self.maxRows - 1 : items.count }
    private var rowCount: Int { items.count > Self.maxRows ? Self.maxRows : items.count }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: Self.headerH + CGFloat(i) * Self.rowH, width: bounds.width, height: Self.rowH)
    }

    private func row(at p: NSPoint) -> Int? {
        guard access == .granted, p.y >= Self.headerH else { return nil }
        let i = Int((p.y - Self.headerH) / Self.rowH)
        return i < rowCount ? i : nil
    }

    private func timeText(_ e: EKEvent) -> String {
        if e.isAllDay { return "Seharian" }
        let c = appCalendar()
        let dayEnd = c.adding(days: 1, to: day)
        let s = e.startDate < day ? "…" : fmtTime.string(from: e.startDate)
        let t = e.endDate > dayEnd ? "…" : fmtTime.string(from: e.endDate)
        return "\(s) – \(t)"
    }

    override func draw(_ dirtyRect: NSRect) {
        // judul: "Jumat, 23 Oktober · Hari ini"
        let head = NSMutableAttributedString(string: fmtDayLong.string(from: day), attributes: attrs(12, .semibold, .labelColor))
        if isToday { head.append(NSAttributedString(string: "  ·  Hari ini", attributes: attrs(12, .regular, .secondaryLabelColor))) }
        head.draw(in: NSRect(x: 8, y: 6, width: bounds.width - 16, height: 17))

        let body = NSRect(x: 0, y: Self.headerH, width: bounds.width, height: bounds.height - Self.headerH)
        switch access {
        case .ask, .denied:
            let msg = access == .ask
                ? "Hubungkan kalender di Mac ini (iCloud, Google, Exchange)\nuntuk menampilkan acara di setiap tanggal."
                : "Akses Kalender ditolak. Izinkan LiteCalendar di\nPengaturan Sistem → Privasi & Keamanan → Kalender."
            var a = attrs(11.5, .regular, .secondaryLabelColor)
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center // dua baris → tanpa truncation
            a[.paragraphStyle] = ps
            (msg as NSString).draw(in: NSRect(x: 16, y: Self.headerH + 18, width: bounds.width - 32, height: 36),
                                   withAttributes: a)
            return
        case .granted:
            break
        }

        if items.isEmpty {
            drawText("Tidak ada acara", in: NSRect(x: 0, y: body.minY, width: body.width, height: 60),
                     attrs(12, .regular, .tertiaryLabelColor, align: .center))
            return
        }

        for i in 0..<rowCount {
            let r = rowRect(i)
            if i == hoverRow {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            if i >= shown {
                drawText("+\(items.count - shown) acara lainnya di Kalender", in: r.insetBy(dx: 18, dy: 0),
                         attrs(11.5, .regular, .secondaryLabelColor))
                continue
            }
            let e = items[i]
            (e.calendar?.color ?? .systemGray).setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: r.midY - 7, width: 3, height: 14), xRadius: 1.5, yRadius: 1.5).fill()
            drawText(timeText(e), in: NSRect(x: 18, y: r.minY, width: 92, height: r.height),
                     attrs(11, .regular, .secondaryLabelColor, mono: true))
            let title = (e.title ?? "").isEmpty ? "(Tanpa judul)" : e.title!
            drawText(title, in: NSRect(x: 114, y: r.minY, width: r.width - 122, height: r.height),
                     attrs(12, .regular, .labelColor))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = row(at: convert(event.locationInWindow, from: nil))
        if i != hoverRow { hoverRow = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) {
        hoverRow = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(i < shown ? items[i] : nil)
    }
}

// MARK: - Isi popover

/// View akar: menangani keyboard (← → T) dan geser trackpad / roda mouse untuk pindah bulan
final class RootView: NSView {
    var onStep: ((Int) -> Void)?
    var onToday: (() -> Void)?
    private var scrollAcc: CGFloat = 0
    private var scrollFired = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onStep?(-1)   // ←
        case 124: onStep?(1)    // →
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "t" { onToday?() }
            else { super.keyDown(with: event) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let d = abs(dx) > abs(dy) ? dx : dy
        if event.phase.isEmpty && event.momentumPhase.isEmpty { // roda mouse biasa: satu langkah per putaran
            if d != 0 { onStep?(d < 0 ? 1 : -1) }
            return
        }
        if event.phase == .began { scrollAcc = 0; scrollFired = false }
        guard event.momentumPhase.isEmpty, !scrollFired else { return }
        scrollAcc += d
        if abs(scrollAcc) > 40 {
            scrollFired = true // satu gesture = satu bulan
            onStep?(scrollAcc < 0 ? 1 : -1)
        }
    }
}

final class CalendarController: NSViewController {
    static let pad: CGFloat = 14, gap: CGFloat = 22

    let source: EventSource
    var settingsMenu: NSMenu?
    weak var popover: NSPopover?
    var firstMonth = defaultFirstMonth()
    var selected = appCalendar().startOfDay(for: Date())
    private var events: [Date: [EKEvent]] = [:]

    private let left = MonthView(), right = MonthView()
    private let agenda = AgendaView(frame: .zero)
    private var todayButton: NSButton!

    init(source: EventSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
        let b = NSButton(image: img, target: self, action: action)
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = true
        b.toolTip = tip
        b.frame.size = NSSize(width: 26, height: 24)
        return b
    }

    private func textButton(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = true
        b.font = .systemFont(ofSize: 12)
        b.toolTip = tip
        b.sizeToFit()
        b.frame.size.height = 24
        return b
    }

    override func loadView() {
        let p = Self.pad, m = MonthView.size
        let width = p * 2 + m.width * 2 + Self.gap
        let root = RootView(frame: .zero)
        root.onStep = { [weak self] n in self?.step(n) }
        root.onToday = { [weak self] in self?.goToday() }

        var y: CGFloat = 8
        left.frame = NSRect(x: p, y: y, width: m.width, height: m.height)
        right.frame = NSRect(x: p + m.width + Self.gap, y: y, width: m.width, height: m.height)
        for v in [left, right] {
            v.onSelect = { [weak self] d in self?.select(d) }
            root.addSubview(v)
        }
        // panah di kiri judul bulan kiri dan kanan judul bulan kanan
        let prev = iconButton("chevron.left", "Bulan sebelumnya (←)", #selector(prevMonth))
        prev.setFrameOrigin(NSPoint(x: p - 4, y: y + 3))
        let next = iconButton("chevron.right", "Bulan berikutnya (→)", #selector(nextMonth))
        next.setFrameOrigin(NSPoint(x: width - p - 22, y: y + 3))
        root.addSubview(prev)
        root.addSubview(next)
        y += m.height + 6

        let sep1 = NSBox(frame: NSRect(x: p, y: y, width: width - p * 2, height: 1))
        sep1.boxType = .separator
        root.addSubview(sep1)
        y += 7

        agenda.frame = NSRect(x: p - 6, y: y, width: width - p * 2 + 12, height: AgendaView.height)
        agenda.onOpen = { [weak self] e in self?.openInCalendar(e) }
        agenda.onAccess = { [weak self] in self?.accessAction() }
        root.addSubview(agenda)
        y += AgendaView.height + 6

        let sep2 = NSBox(frame: NSRect(x: p, y: y, width: width - p * 2, height: 1))
        sep2.boxType = .separator
        root.addSubview(sep2)
        y += 7

        let gear = iconButton("gearshape", "Pengaturan", #selector(showSettings(_:)))
        gear.setFrameOrigin(NSPoint(x: p - 4, y: y))
        root.addSubview(gear)
        let open = textButton("Buka Kalender", "Buka aplikasi Kalender", #selector(openCalendarApp))
        open.setFrameOrigin(NSPoint(x: width - p + 4 - open.frame.width, y: y))
        root.addSubview(open)
        todayButton = textButton("Hari ini", "Kembali ke hari ini (T)", #selector(todayClicked))
        todayButton.setFrameOrigin(NSPoint(x: open.frame.minX - 4 - todayButton.frame.width, y: y))
        root.addSubview(todayButton)
        y += 24 + 8

        root.frame = NSRect(x: 0, y: 0, width: width, height: y)
        view = root
        reload()
    }

    // MARK: navigasi

    func step(_ n: Int) {
        firstMonth = appCalendar().adding(months: n, to: firstMonth)
        reload()
    }
    /// Kembali ke tampilan awal (aturan tanggal 15) dan pilih hari ini
    func goToday() {
        firstMonth = defaultFirstMonth()
        selected = appCalendar().startOfDay(for: Date())
        reload()
    }
    func select(_ d: Date) {
        selected = d
        reload()
    }
    @objc func prevMonth() { step(-1) }
    @objc func nextMonth() { step(1) }
    @objc func todayClicked() { goToday() }

    func reload() {
        guard isViewLoaded else { return }
        let c = appCalendar()
        let start = firstMonth, end = c.adding(months: 2, to: firstMonth)
        events = source.eventsByDay(from: start, to: end, cal: c)
        left.month = start
        right.month = c.adding(months: 1, to: start)
        for v in [left, right] {
            v.events = events
            v.selected = selected
            v.needsDisplay = true
        }

        let today = c.startOfDay(for: Date())
        agenda.day = selected
        agenda.isToday = selected == today
        if selected >= start && selected < end {
            agenda.items = events[selected] ?? []
        } else {
            let next = c.adding(days: 1, to: selected)
            agenda.items = source.eventsByDay(from: selected, to: next, cal: c)[selected] ?? []
        }
        agenda.access = source.hasAccess ? .granted : source.canAsk ? .ask : .denied
        agenda.needsDisplay = true
        todayButton.isEnabled = !(firstMonth == defaultFirstMonth() && selected == today)
    }

    // MARK: aksi

    @objc func showSettings(_ sender: NSButton) {
        _ = settingsMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func accessAction() {
        if source.canAsk {
            source.requestAccess { [weak self] _ in self?.reload() }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openCalendarApp() { openInCalendar(nil) }

    /// Buka acara di aplikasi Kalender (atau aplikasinya saja kalau acara tidak diketahui)
    func openInCalendar(_ e: EKEvent?) {
        if let id = e?.calendarItemIdentifier,
           let q = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(q)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            popover?.performClose(nil)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        popover?.performClose(nil)
    }
}

// MARK: - Update (cek rilis terbaru di GitHub Releases)

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-calendar-two-sided"
    let appName = "LiteCalendar"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    var latest: (version: String, zip: URL?, page: URL)?
    var timer: Timer?

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "v1.2.0" lebih baru dari "1.1"?
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var hasUpdate: Bool { latest.map { Updater.isNewer($0.version, than: Updater.current) } ?? false }

    override init() {
        super.init()
        menuItem.target = self
    }

    /// Cek diam-diam saat aplikasi dibuka lalu sehari sekali; kalau ada versi baru, judul menu berubah
    func start() {
        check { [weak self] _ in self?.refreshMenu() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check { _ in self?.refreshMenu() }
        }
        t.tolerance = 3600 // tidak perlu tepat waktu → hemat energi
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshMenu() {
        menuItem.isEnabled = true
        if let l = latest, hasUpdate { menuItem.title = "Update tersedia: \(l.version)…" }
        else { menuItem.title = "Cek pembaruan…" }
    }

    /// Ambil info rilis terbaru; done(true) kalau berhasil (dipanggil di main thread)
    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var info: (String, URL?, URL)?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = j["tag_name"] as? String,
               let page = (j["html_url"] as? String).flatMap({ URL(string: $0) }) {
                let assets = j["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String) == "\(self.appName).zip" }?["browser_download_url"] as? String
                info = (tag, zip.flatMap { URL(string: $0) }, page)
            }
            DispatchQueue.main.async {
                if let info { self.latest = (info.0, info.1, info.2) }
                done(info != nil)
            }
        }.resume()
    }

    @objc func checkNow() {
        menuItem.title = "Mengecek pembaruan…"
        menuItem.isEnabled = false
        check { [weak self] ok in
            guard let self else { return }
            self.refreshMenu()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Gagal mengecek pembaruan"
                a.informativeText = "Periksa koneksi internet, lalu coba lagi."
                a.runModal()
                return
            }
            guard self.hasUpdate else {
                a.messageText = "\(self.appName) sudah versi terbaru"
                a.informativeText = "Versi terpasang: \(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "\(self.appName) \(l.version) tersedia"
            a.informativeText = "Versi terpasang: \(Updater.current).\n\n\(self.appName) akan ditutup, diganti versi baru, lalu dibuka lagi. Pengaturan tetap tersimpan."
            a.addButton(withTitle: "Update sekarang")
            a.addButton(withTitle: "Lihat rilis")
            a.addButton(withTitle: "Nanti")
            switch a.runModal() {
            case .alertFirstButtonReturn: self.install(l)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(l.page)
            default: break
            }
        }
    }

    /// Unduh .zip rilis, ekstrak, lalu ganti .app lama setelah aplikasi ini keluar
    func install(_ l: (version: String, zip: URL?, page: URL)) {
        let dest = Bundle.main.bundleURL
        // tanpa file .zip, bukan .app, atau folder tidak bisa ditulis → unduh manual dari halaman rilis
        guard let zip = l.zip, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
            let zipFile = work.appendingPathComponent("update.zip")
            let newApp = work.appendingPathComponent("\(self.appName).app")
            var problem: String?
            if let tmp {
                do {
                    // file sementara dihapus setelah handler ini selesai → pindahkan sekarang
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: zipFile)
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    if unzip.terminationStatus != 0 || !fm.fileExists(atPath: newApp.path) {
                        problem = "File rilis tidak berisi \(self.appName).app."
                    }
                } catch { problem = error.localizedDescription }
            } else {
                problem = err?.localizedDescription ?? "Unduhan gagal."
            }
            DispatchQueue.main.async {
                if let problem { return self.fail(problem, l.page) }
                // skrip kecil: tunggu aplikasi ini keluar, tukar .app (lama dicadangkan dulu), lalu buka lagi
                let script = """
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                if mv "$3" "$4"; then
                  if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
                fi
                xattr -cr "$3" 2>/dev/null
                open "$3"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", String(getpid()), newApp.path, dest.path,
                               work.appendingPathComponent("old.app").path]
                do { try p.run() } catch { return self.fail(error.localizedDescription, l.page) }
                NSApp.terminate(nil)
            }
        }.resume()
    }

    func fail(_ msg: String, _ page: URL) {
        refreshMenu()
        let a = NSAlert()
        a.messageText = "Update gagal"
        a.informativeText = "\(msg)\n\nHalaman rilis akan dibuka supaya Anda bisa mengunduh manual."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        NSWorkspace.shared.open(page)
    }
}

// MARK: - Aplikasi

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let source = EventSource()
    lazy var controller = CalendarController(source: source)
    let updater = Updater()
    var lastClose = Date.distantPast

    // menu pengaturan (klik kanan ikon atau tombol ⚙︎ di popover)
    let menu = NSMenu()
    let calMenu = NSMenu()
    var styleItems: [NSMenuItem] = []
    var weekItems: [NSMenuItem] = []
    let loginItem = NSMenuItem(title: "Buka saat login", action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["barStyle": 0, "firstWeekday": 0])
        statusItem.autosaveName = "LiteCalendar" // posisi ikon diingat
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildMenu()
        controller.settingsMenu = menu
        controller.popover = popover
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.delegate = self
        updateBar()

        let nc = NotificationCenter.default
        // ganti hari / zona waktu / bangun dari sleep → perbarui ikon tanggal
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.dayChanged() }
        nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.dayChanged() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.dayChanged() }
        // acara berubah (sinkron Google/iCloud, diedit di Kalender) → muat ulang kalau popover terbuka
        nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            if self?.popover.isShown == true { self?.controller.reload() }
        }

        if source.canAsk { source.requestAccess { [weak self] _ in self?.controller.reload() } }
        updater.start()
    }

    func dayChanged() {
        updateBar()
        if popover.isShown { controller.goToday() }
    }

    func updateBar() {
        guard let b = statusItem.button else { return }
        let now = Date()
        if defaults.integer(forKey: "barStyle") == 1 {
            b.image = nil
            b.title = fmtBar.string(from: now)
            b.imagePosition = .noImage
        } else {
            b.image = renderBarIcon(day: appCalendar().component(.day, from: now))
            b.title = ""
            b.imagePosition = .imageOnly
        }
        b.toolTip = fmtDayLong.string(from: now)
    }

    // MARK: popover

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        // klik ikon saat popover terbuka: popover sudah ditutup oleh klik itu sendiri → jangan buka lagi
        if Date().timeIntervalSince(lastClose) < 0.3 { return }
        controller.goToday() // selalu mulai dari tampilan awal
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(controller.view)
        sender.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        statusItem.button?.highlight(false)
    }

    // MARK: menu pengaturan

    func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        let styleMenu = NSMenu()
        for (title, v) in [("Ikon tanggal", 0), ("Teks (Jum 23 Okt)", 1)] {
            let it = NSMenuItem(title: title, action: #selector(setStyle(_:)), keyEquivalent: "")
            it.target = self
            it.tag = v
            styleMenu.addItem(it)
            styleItems.append(it)
        }
        let styleItem = NSMenuItem(title: "Tampilan menu bar", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let weekMenu = NSMenu()
        for (title, v) in [("Ikuti sistem", 0), ("Senin", 2), ("Minggu", 1)] {
            let it = NSMenuItem(title: title, action: #selector(setWeekStart(_:)), keyEquivalent: "")
            it.target = self
            it.tag = v
            weekMenu.addItem(it)
            weekItems.append(it)
        }
        let weekItem = NSMenuItem(title: "Minggu dimulai hari", action: nil, keyEquivalent: "")
        weekItem.submenu = weekMenu
        menu.addItem(weekItem)

        calMenu.autoenablesItems = false
        let calItem = NSMenuItem(title: "Kalender yang ditampilkan", action: nil, keyEquivalent: "")
        calItem.submenu = calMenu
        menu.addItem(calItem)
        let google = NSMenuItem(title: "Tambah akun Google / lainnya…", action: #selector(openInternetAccounts), keyEquivalent: "")
        google.target = self
        menu.addItem(google)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(updater.menuItem)
        let un = NSMenuItem(title: "Uninstall LiteCalendar…", action: #selector(uninstall), keyEquivalent: "")
        un.target = self
        menu.addItem(un)
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === menu else { return }
        let style = defaults.integer(forKey: "barStyle"), week = defaults.integer(forKey: "firstWeekday")
        for it in styleItems { it.state = it.tag == style ? .on : .off }
        for it in weekItems { it.state = it.tag == week ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        rebuildCalendarMenu()
    }

    /// Daftar kalender per akun (iCloud, Google, …) dengan centang
    func rebuildCalendarMenu() {
        calMenu.removeAllItems()
        guard source.hasAccess else {
            let it = NSMenuItem(title: "Belum ada akses Kalender", action: nil, keyEquivalent: "")
            it.isEnabled = false
            calMenu.addItem(it)
            return
        }
        let hidden = source.hiddenCalendars
        let groups = Dictionary(grouping: source.calendars) { $0.source?.title ?? "Lainnya" }
        for (i, name) in groups.keys.sorted().enumerated() {
            if i > 0 { calMenu.addItem(.separator()) }
            let head = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            head.isEnabled = false
            calMenu.addItem(head)
            for c in (groups[name] ?? []).sorted(by: { $0.title < $1.title }) {
                let it = NSMenuItem(title: c.title, action: #selector(toggleCalendar(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.calendarIdentifier
                it.image = colorDot(c.color ?? .systemGray)
                it.state = hidden.contains(c.calendarIdentifier) ? .off : .on
                calMenu.addItem(it)
            }
        }
    }

    // MARK: aksi

    @objc func setStyle(_ s: NSMenuItem) {
        defaults.set(s.tag, forKey: "barStyle")
        updateBar()
    }
    @objc func setWeekStart(_ s: NSMenuItem) {
        defaults.set(s.tag, forKey: "firstWeekday")
        controller.reload()
    }
    @objc func toggleCalendar(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        var h = source.hiddenCalendars
        if h.contains(id) { h.remove(id) } else { h.insert(id) }
        source.hiddenCalendars = h
        controller.reload()
    }
    /// Akun Google ditambahkan lewat Pengaturan Sistem → Akun Internet, lalu otomatis terbaca lewat EventKit
    @objc func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"),
           NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Gagal mengatur 'Buka saat login'"
            a.informativeText = "Pastikan LiteCalendar.app ada di folder Applications.\n\n\(error.localizedDescription)"
            a.runModal()
        }
    }

    /// Hapus LiteCalendar dari Mac: login item, pengaturan, lalu .app dipindahkan ke Tong Sampah
    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall LiteCalendar?"
        a.informativeText = "LiteCalendar akan dihapus dari 'Buka saat login', pengaturannya dihapus, lalu LiteCalendar.app dipindahkan ke Tong Sampah dan aplikasi ditutup. Acara di kalender Anda tidak tersentuh."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: id)
            defaults.synchronize()
            // cabut izin Kalender (best effort)
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            t.arguments = ["reset", "Calendar", id]
            if (try? t.run()) != nil { t.waitUntilExit() }
        }
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension != "app" || (try? FileManager.default.trashItem(at: appURL, resultingItemURL: nil)) == nil {
            // tidak punya izin tulis (mis. dipasang oleh admin lain) → minta pengguna menghapus manual
            let f = NSAlert()
            f.messageText = "LiteCalendar.app tidak bisa dipindahkan otomatis"
            f.informativeText = "Pengaturan sudah dihapus. Seret LiteCalendar.app ke Tong Sampah secara manual."
            f.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon di Dock
app.run()
