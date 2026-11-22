import AVFoundation
import AppKit
import CoreAudioKit
import Observation

/// Audio Unit plug-ins on the recording, the same kind Logic Pro loads. They sit between the clean-up and the
/// loudness step, in order, and are remembered between launches.
///
/// Other companies' plug-ins run in a process of their own wherever they can, so one that crashes can't take the app
/// down with it. Apple's own run inside the app. Logic Pro's built-in plug-ins (Channel EQ, Compressor and so on) live
/// inside Logic and aren't available to other apps; plug-ins installed separately are.
@MainActor @Observable final class PluginChain {
    struct Available: Identifiable, Hashable, Sendable {
        let name: String
        let manufacturer: String
        let type: UInt32
        let subType: UInt32
        let manufacturerCode: UInt32

        var id: String { "\(type).\(subType).\(manufacturerCode)" }

        var description: AudioComponentDescription {
            AudioComponentDescription(
                componentType: type,
                componentSubType: subType,
                componentManufacturer: manufacturerCode,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        }
    }

    @MainActor @Observable final class Loaded: Identifiable {
        let id = UUID()
        let source: Available
        /// The copy that plays in the preview, and whose window is shown.
        let unit: AVAudioUnit
        var isOn = true
        /// Which stretches it works on: everything, only talk, or only songs.
        var scope = InsertScope.everything

        @ObservationIgnored fileprivate var window: NSWindow?
        @ObservationIgnored fileprivate var closeObserver: NSObjectProtocol?

        var name: String { source.name }

        init(source: Available, unit: AVAudioUnit) {
            self.source = source
            self.unit = unit
        }
    }

    /// What's saved between launches for each plug-in.
    struct Entry: Codable, Sendable {
        var name: String
        var manufacturer: String
        var type: UInt32
        var subType: UInt32
        var manufacturerCode: UInt32
        var isOn: Bool
        var state: Data?
        /// Missing from plug-ins saved before effects could be kept to talk or songs.
        var scope: InsertScope?
    }

    /// The first time this app uses another company's plug-in, macOS asks whether to allow it, and loading waits for
    /// the answer. So a plug-in gets a few minutes, not seconds, before it's taken as stuck.
    private static let longestWaitForPlugin: TimeInterval = 180
    private static let key = "pluginChain"

    private(set) var available: [Available] = []
    private(set) var loaded: [Loaded] = []
    private(set) var isLoading = false
    /// The name of a plug-in that wouldn't load, to say so instead of quietly doing nothing.
    var pluginThatFailed: String?
    /// The offline copies, kept between renders: loading another company's plug-in takes a while, and settings
    /// change far more often than the list does.
    @ObservationIgnored private var renderUnits: [UUID: AVAudioUnit] = [:]

    /// Called when what the chain does to the sound may have changed: a plug-in added, removed, moved, switched, or
    /// its window closed after changing settings.
    @ObservationIgnored var onChange: () -> Void = {}

    var manufacturers: [String] {
        var seen: Set<String> = []
        return available.map(\.manufacturer).filter { seen.insert($0).inserted }
    }

    // MARK: - Finding and adding

    func findAvailablePlugins() {
        guard available.isEmpty else { return }
        Task { available = await Self.installedPlugins() }
    }

    @concurrent nonisolated private static func installedPlugins() async -> [Available] {
        let kinds: [OSType] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        let components = kinds.flatMap { kind in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: kind,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            ))
        }
        return components
            .map { component in
                let description = component.audioComponentDescription
                return Available(
                    name: component.name,
                    manufacturer: component.manufacturerName,
                    type: description.componentType,
                    subType: description.componentSubType,
                    manufacturerCode: description.componentManufacturer
                )
            }
            .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }

    func add(_ plugin: Available) {
        isLoading = true
        pluginThatFailed = nil
        Task {
            defer { isLoading = false }
            guard let unit = await load(plugin) else {
                pluginThatFailed = plugin.name
                return
            }
            let new = Loaded(source: plugin, unit: unit)
            loaded.append(new)
            changed()
            openEditor(of: new)
        }
    }

    func remove(_ plugin: Loaded) {
        plugin.window?.close()
        loaded.removeAll { $0.id == plugin.id }
        changed()
    }

    func move(_ plugin: Loaded, by offset: Int) {
        guard let index = loaded.firstIndex(where: { $0.id == plugin.id }) else { return }
        let target = min(max(index + offset, 0), loaded.count - 1)
        guard target != index else { return }
        let plugin = loaded.remove(at: index)
        loaded.insert(plugin, at: target)
        changed()
    }

    func setOn(_ isOn: Bool, for plugin: Loaded) {
        plugin.isOn = isOn
        changed()
    }

    func setScope(_ scope: InsertScope, for plugin: Loaded) {
        guard plugin.scope != scope else { return }
        plugin.scope = scope
        changed()
    }

    // MARK: - Saving

    /// Loads the plug-ins saved last time, in order. Plug-ins that won't load are left out and named.
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data),
              !entries.isEmpty
        else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            for entry in entries {
                let source = Available(
                    name: entry.name,
                    manufacturer: entry.manufacturer,
                    type: entry.type,
                    subType: entry.subType,
                    manufacturerCode: entry.manufacturerCode
                )
                guard let unit = await load(source) else {
                    pluginThatFailed = entry.name
                    continue
                }
                Self.apply(entry.state, to: unit)
                let new = Loaded(source: source, unit: unit)
                new.isOn = entry.isOn
                new.scope = entry.scope ?? .everything
                loaded.append(new)
            }
            onChange()
        }
    }

    private func save() {
        let entries = loaded.map { plugin in
            Entry(
                name: plugin.name,
                manufacturer: plugin.source.manufacturer,
                type: plugin.source.type,
                subType: plugin.source.subType,
                manufacturerCode: plugin.source.manufacturerCode,
                isOn: plugin.isOn,
                state: plugin.unit.auAudioUnit.fullState.flatMap {
                    try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
                },
                scope: plugin.scope
            )
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func changed() {
        save()
        onChange()
    }

    private static func apply(_ state: Data?, to unit: AVAudioUnit) {
        guard let state,
              let settings = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
        else { return }
        unit.auAudioUnit.fullState = settings
    }

    /// New copies of the plug-ins that are on, with the same settings, for rendering the whole recording offline. The
    /// preview's own copies keep playing meanwhile, since a plug-in can only be in one place.
    /// Only one render uses them at a time: a new render waits for the one it replaces to stop.
    func renderCopies() async -> [RenderInsert] {
        renderUnits = renderUnits.filter { id, _ in loaded.contains { $0.id == id } }
        var inserts: [RenderInsert] = []
        for plugin in loaded where plugin.isOn {
            var copy = renderUnits[plugin.id]
            if copy == nil {
                copy = await load(plugin.source)
                renderUnits[plugin.id] = copy
            }
            guard let unit = copy else {
                pluginThatFailed = plugin.name
                continue
            }
            unit.auAudioUnit.fullState = plugin.unit.auAudioUnit.fullState
            unit.reset()
            inserts.append(RenderInsert(unit: unit, scope: plugin.scope))
        }
        return inserts
    }

    // MARK: - Loading

    /// Apple's run inside the app, which costs less. Everyone else's run in a process of their own. Copy-protected
    /// plug-ins, like Universal Audio's, would be closed on the spot inside the app: they rewrite their own code as
    /// they start, which macOS doesn't allow here.
    private func load(_ plugin: Available) async -> AVAudioUnit? {
        if plugin.manufacturerCode == kAudioUnitManufacturer_Apple {
            if let unit = await load(plugin, options: []) { return unit }
            return await load(plugin, options: .loadOutOfProcess)
        }
        let start = ContinuousClock.now
        if let unit = await load(plugin, options: .loadOutOfProcess) { return unit }
        // Turned down quickly, as can happen while the plug-in service is still starting just after launch, it gets
        // one more try. One that took its time already had its chance.
        guard ContinuousClock.now - start < .seconds(5) else { return nil }
        try? await Task.sleep(for: .seconds(1))
        return await load(plugin, options: .loadOutOfProcess)
    }

    /// A plug-in can sit waiting for a licence check, or for the person to answer macOS's question, so it only gets so
    /// long to answer.
    private func load(_ plugin: Available, options: AudioComponentInstantiationOptions) async -> AVAudioUnit? {
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<UnitBox?, Never>) in
            let answer = SingleAnswer(continuation)
            AVAudioUnit.instantiate(with: plugin.description, options: options) { unit, _ in
                answer.give(unit.map(UnitBox.init))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.longestWaitForPlugin) {
                answer.give(nil)
            }
        }
        return box?.unit
    }

    /// Whichever comes first, the plug-in or the time limit, is the answer.
    private final class SingleAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UnitBox?, Never>?

        init(_ continuation: CheckedContinuation<UnitBox?, Never>) {
            self.continuation = continuation
        }

        func give(_ unit: UnitBox?) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: unit)
        }
    }

    // MARK: - Windows

    func openEditor(of plugin: Loaded) {
        if let window = plugin.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        plugin.unit.auAudioUnit.requestViewController { [weak self, weak plugin] controller in
            let box = ControllerBox(controller)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let plugin else { return }
                    self.showWindow(for: plugin, with: box.controller)
                }
            }
        }
    }

    /// A plug-in with no window of its own still gets plain controls for its settings.
    private func showWindow(for plugin: Loaded, with controller: NSViewController?) {
        let content: NSViewController
        if let controller {
            content = controller
        } else {
            let generic = AUGenericViewController()
            generic.auAudioUnit = plugin.unit.auAudioUnit
            content = generic
        }
        let window = NSWindow(contentViewController: content)
        window.title = plugin.name
        window.isReleasedWhenClosed = false
        if content.preferredContentSize != .zero {
            window.setContentSize(content.preferredContentSize)
        }
        plugin.window = window
        plugin.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak plugin] _ in
            MainActor.assumeIsolated {
                plugin?.window = nil
                // Settings may have changed while it was open; the preview heard them live, the export now catches up.
                self?.changed()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ControllerBox: @unchecked Sendable {
    let controller: NSViewController?

    init(_ controller: NSViewController?) {
        self.controller = controller
    }
}
