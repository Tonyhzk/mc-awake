import Foundation

enum PowerSource {
    case ac
    case battery
}

struct PowerSnapshot {
    let source: PowerSource?
    let batteryPercent: Int?

    init(output: String) {
        let firstLine = output.split(separator: "\n").first ?? ""
        if firstLine.contains("'AC Power'") {
            source = .ac
        } else if firstLine.contains("'Battery Power'") {
            source = .battery
        } else {
            source = nil
        }
        if let range = output.range(of: #"\d+%"#, options: .regularExpression),
           let value = Int(output[range].dropLast()), (0...100).contains(value) {
            batteryPercent = value
        } else {
            batteryPercent = nil
        }
    }
}

enum BatteryGuardEvent {
    case tripped
    case rearmed
}

struct BatteryGuardTracker {
    private var initialized = false
    private var active = false

    mutating func observe(mode: String?, awake: Bool?, power: PowerSnapshot) -> BatteryGuardEvent? {
        guard let mode else { return nil }
        guard mode == "always" else {
            initialized = false
            active = false
            return nil
        }
        guard let awake, let source = power.source else { return nil }
        if source == .battery && power.batteryPercent == nil { return nil }

        if !initialized {
            initialized = true
            active = source == .battery && !awake && (power.batteryPercent ?? 100) < 18
            return nil
        }

        if !active, source == .battery, !awake,
           let percent = power.batteryPercent, percent <= 15 {
            active = true
            return .tripped
        }
        if active, awake,
           source == .ac || (power.batteryPercent.map { $0 >= 18 } ?? false) {
            active = false
            return .rearmed
        }
        return nil
    }
}
