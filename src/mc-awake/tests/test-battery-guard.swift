import Foundation

@main
struct BatteryGuardTests {
    static var checks = 0

    static func expect(_ actual: BatteryGuardEvent?, _ expected: BatteryGuardEvent?, _ scenario: String) {
        checks += 1
        guard actual == expected else {
            fatalError("\(scenario): 实际 \(String(describing: actual))，预期 \(String(describing: expected))")
        }
    }

    static func battery(_ percent: Int?) -> PowerSnapshot {
        let charge = percent.map { " -InternalBattery-0 (id=123)\t\($0)%; discharging" } ?? ""
        return PowerSnapshot(output: "Now drawing from 'Battery Power'\n\(charge)")
    }

    static func ac() -> PowerSnapshot {
        PowerSnapshot(output: "Now drawing from 'AC Power'\n")
    }

    static func main() {
        var healthy = BatteryGuardTracker()
        expect(healthy.observe(mode: "always", awake: true, power: battery(55)), nil, "高电量初始状态")
        for _ in 0..<3 {
            expect(healthy.observe(mode: "always", awake: false, power: battery(55)), nil, "高电量时允许睡眠")
            expect(healthy.observe(mode: "always", awake: true, power: battery(55)), nil, "高电量时恢复禁止睡眠")
        }
        expect(healthy.observe(mode: "always", awake: false, power: ac()), nil, "接电时允许睡眠")
        expect(healthy.observe(mode: "always", awake: true, power: ac()), nil, "接电时恢复禁止睡眠")

        var guardState = BatteryGuardTracker()
        expect(guardState.observe(mode: "always", awake: true, power: battery(16)), nil, "低电量前的初始状态")
        expect(guardState.observe(mode: "always", awake: true, power: battery(15)), nil, "等待守护进程允许睡眠")
        expect(guardState.observe(mode: "always", awake: false, power: battery(15)), .tripped, "15% 触发保护")
        expect(guardState.observe(mode: "always", awake: false, power: battery(14)), nil, "保护期间不重复通知")
        expect(guardState.observe(mode: "always", awake: false, power: battery(16)), nil, "16% 保持保护")
        expect(guardState.observe(mode: "always", awake: false, power: battery(17)), nil, "17% 保持保护")
        expect(guardState.observe(mode: "always", awake: true, power: battery(17)), nil, "17% 不报告恢复")
        expect(guardState.observe(mode: "always", awake: true, power: battery(18)), .rearmed, "18% 恢复保护")
        expect(guardState.observe(mode: "always", awake: false, power: battery(55)), nil, "恢复后普通状态变化")
        expect(guardState.observe(mode: "always", awake: true, power: battery(55)), nil, "恢复后不重复通知")

        expect(guardState.observe(mode: "always", awake: false, power: battery(15)), .tripped, "再次触发保护")
        expect(guardState.observe(mode: "always", awake: nil, power: ac()), nil, "睡眠状态未知时等待")
        expect(guardState.observe(mode: nil, awake: true, power: ac()), nil, "模式未知时等待")
        expect(guardState.observe(mode: "always", awake: true, power: battery(nil)), nil, "电量未知时等待")
        expect(guardState.observe(mode: "always", awake: true, power: PowerSnapshot(output: "")), nil, "电源未知时等待")
        expect(guardState.observe(mode: "always", awake: false, power: ac()), nil, "接电后等待禁止睡眠")
        expect(guardState.observe(mode: "always", awake: true, power: ac()), .rearmed, "接电后恢复保护")

        var restarted = BatteryGuardTracker()
        expect(restarted.observe(mode: "always", awake: false, power: battery(15)), nil, "低电量启动不立即通知")
        expect(restarted.observe(mode: "always", awake: true, power: battery(18)), .rearmed, "低电量启动后恢复")
        var restartedInBand = BatteryGuardTracker()
        expect(restartedInBand.observe(mode: "always", awake: false, power: battery(17)), nil, "滞回区间启动")
        expect(restartedInBand.observe(mode: "always", awake: true, power: battery(18)), .rearmed, "滞回区间启动后恢复")

        var switched = BatteryGuardTracker()
        expect(switched.observe(mode: "always", awake: true, power: battery(20)), nil, "切换前的初始状态")
        expect(switched.observe(mode: "always", awake: false, power: battery(15)), .tripped, "切换前触发保护")
        expect(switched.observe(mode: "auto", awake: false, power: battery(15)), nil, "切换模式清除保护状态")
        expect(switched.observe(mode: "always", awake: true, power: battery(55)), nil, "返回持续唤醒不误报")
        expect(switched.observe(mode: "always", awake: false, power: battery(55)), nil, "切换后高电量允许睡眠")
        expect(switched.observe(mode: "always", awake: true, power: battery(55)), nil, "切换后高电量恢复禁止睡眠")

        print("\(checks) 项电池保护通知测试通过")
    }
}
