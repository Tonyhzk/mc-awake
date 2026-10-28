import Cocoa

final class LocalizationTestDelegate: AppDelegate {
    var iconRefreshes = 0

    override func refreshIcon() {
        iconRefreshes += 1
    }
}

@main
struct LocalizationTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ scenario: String) {
        checks += 1
        guard condition() else { fatalError(scenario) }
    }

    static func languageItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.compactMap { $0.submenu }.flatMap { $0.items }
            .filter { $0.action == #selector(AppDelegate.selectLanguage(_:)) }
    }

    static func savedLanguage(in suite: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", suite, AppLocalization.languageKey]
        let output = Pipe()
        process.standardOutput = output
        try! process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "独立进程应能读取语言偏好")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func main() {
        let suite = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("localization").path
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = AppLocalization(defaults: defaults)

        expect(localization.language == .simplifiedChinese, "默认语言应为简体中文")
        expect(localization.text("A", "B") == "A", "默认应选择第一个语言参数")
        defaults.set("unsupported", forKey: AppLocalization.languageKey)
        expect(localization.language == .simplifiedChinese, "无效语言应回退到简体中文")
        localization.language = .english
        expect(localization.text("A", "B") == "B", "英文应选择第二个语言参数")
        let reopened = AppLocalization(defaults: UserDefaults(suiteName: suite)!)
        expect(reopened.language == .english, "英文选择应在重新读取后保留")
        expect(savedLanguage(in: suite) == AppLanguage.english.rawValue, "独立进程应读取到英文选择")
        localization.language = .simplifiedChinese
        expect(reopened.language == .simplifiedChinese, "切换回中文后应保留选择")
        expect(savedLanguage(in: suite) == AppLanguage.simplifiedChinese.rawValue, "独立进程应读取到中文选择")

        _ = NSApplication.shared
        let delegate = LocalizationTestDelegate(localization: localization)
        delegate.cachedServices = [LocalService(name: "node", pid: 42, ports: [8080])]
        delegate.cachedTunnels = [Tunnel(name: "ngrok", pid: 43)]
        delegate.cachedSessions = [ClaudeSession(pid: 44, tty: "ttys001", etime: "01:00",
                                                 cwd: "/tmp/project", name: "test", busy: true)]
        let menu = NSMenu()
        delegate.buildMenu(menu)
        var options = languageItems(menu)
        expect(options.count == AppLanguage.allCases.count, "菜单应提供全部语言选项")
        guard let chinese = options.first(where: { $0.representedObject as? String == AppLanguage.simplifiedChinese.rawValue }),
              let english = options.first(where: { $0.representedObject as? String == AppLanguage.english.rawValue }) else {
            fatalError("语言菜单缺少选项")
        }
        expect(chinese.state == .on && english.state == .off, "默认菜单应勾选中文")
        expect(english.target === delegate, "语言菜单应连接到应用代理")
        delegate.selectLanguage(english)
        expect(localization.language == .english && reopened.language == .english, "菜单操作应保存英文")
        expect(delegate.iconRefreshes == 1, "语言变更应刷新状态栏")
        delegate.buildMenu(menu)
        options = languageItems(menu)
        expect(options.first(where: { $0.representedObject as? String == AppLanguage.english.rawValue })?.state == .on,
               "重新打开菜单应勾选英文")
        guard let nextChinese = options.first(where: { $0.representedObject as? String == AppLanguage.simplifiedChinese.rawValue }) else {
            fatalError("语言菜单缺少中文选项")
        }
        delegate.selectLanguage(nextChinese)
        expect(reopened.language == .simplifiedChinese, "菜单操作应保存中文")
        expect(delegate.iconRefreshes == 2, "切换回中文应刷新状态栏")
        let invalid = NSMenuItem()
        invalid.representedObject = "unsupported"
        delegate.selectLanguage(invalid)
        expect(localization.language == .simplifiedChinese && delegate.iconRefreshes == 2, "无效选项不应修改语言或刷新")
        print("\(checks) 项语言设置测试通过")
    }
}
