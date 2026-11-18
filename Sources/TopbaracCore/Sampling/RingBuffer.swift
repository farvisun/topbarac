import Foundation

/// Fixed-capacity FIFO. Appending past capacity drops the oldest element. O(1) append, no reallocation.
public struct RingBuffer<Element>: Sequence {
    private var storage: [Element?]
    private var head = 0          // index of the oldest element
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    public mutating func append(_ value: Element) {
        let index = (head + count) % capacity
        storage[index] = value
        if count < capacity { count += 1 } else { head = (head + 1) % capacity }
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    public var isEmpty: Bool { count == 0 }
    public var last: Element? { count == 0 ? nil : storage[(head + count - 1) % capacity] }
    public var first: Element? { count == 0 ? nil : storage[head] }

    public subscript(i: Int) -> Element {
        precondition(i >= 0 && i < count)
        return storage[(head + i) % capacity]!
    }

    public func makeIterator() -> AnyIterator<Element> {
        var i = 0
        return AnyIterator {
            guard i < self.count else { return nil }
            defer { i += 1 }
            return self[i]
        }
    }

    /// Last `n` elements, oldest first.
    public func suffix(_ n: Int) -> [Element] {
        let n = Swift.min(n, count)
        return (count - n..<count).map { self[$0] }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

/// One point of a metric series. `value == nil` marks a gap (sleep, counter reset): charts break the line there.
public struct SeriesPoint: Sendable, Equatable, Identifiable {
    public var time: Date
    public var value: Double?
    public var id: Date { time }
    public init(time: Date, value: Double?) { self.time = time; self.value = value }
}

/// Fixed one-hour-ish history of a single series (capacity in samples, the time span depends on the refresh interval).
public struct SeriesHistory: Sendable {
    public private(set) var points: RingBuffer<SeriesPoint>

    public init(capacity: Int = 3600) { points = RingBuffer(capacity: capacity) }

    public mutating func append(_ value: Double?, at time: Date) {
        // Never append two gaps in a row: one is enough to break the chart.
        if value == nil, let last = points.last, last.value == nil { return }
        points.append(SeriesPoint(time: time, value: value))
    }

    public var latest: Double? { points.last?.value }

    /// Points newer than `since`, averaged into at most `maxPoints` buckets so charts stay cheap.
    /// A bucket that holds only gaps stays a gap.
    public func window(since: Date, maxPoints: Int = 240) -> [SeriesPoint] {
        var selected: [SeriesPoint] = []
        selected.reserveCapacity(min(points.count, 3600))
        for p in points where p.time >= since { selected.append(p) }
        return Self.downsample(selected, maxPoints: maxPoints)
    }

    public static func downsample(_ points: [SeriesPoint], maxPoints: Int) -> [SeriesPoint] {
        guard points.count > maxPoints, maxPoints > 0 else { return points }
        let size = Int((Double(points.count) / Double(maxPoints)).rounded(.up))
        var out: [SeriesPoint] = []
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < points.count {
            let chunk = points[i..<min(i + size, points.count)]
            let values = chunk.compactMap(\.value)
            let time = chunk.last!.time
            if chunk.contains(where: { $0.value == nil }) && values.count < chunk.count / 2 {
                out.append(SeriesPoint(time: time, value: nil))
            } else {
                out.append(SeriesPoint(time: time, value: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)))
            }
            i += size
        }
        return out
    }
}
