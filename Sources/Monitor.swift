import AppKit

struct Payload: @unchecked Sendable { let value: [String: Any] }

/// Owns the sampling queue. The sampler, and every action that reads its state, run on this
/// one serial queue, so nothing races.
final class Monitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.brokengearindustries.macsense.monitor", qos: .utility)
    private var sampler: Sampler?
    private var timer: DispatchSourceTimer?

    func start(every interval: Double = 1, onSample: @escaping @Sendable (Payload) -> Void) {
        queue.async { [self] in
            let sampler = Sampler()
            sampler.prime()
            self.sampler = sampler
            onSample(Payload(value: sampler.initialSample()))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { onSample(Payload(value: sampler.sample())) }
            timer.resume()
            self.timer = timer
        }
    }

    func volumesChanged() { queue.async { self.sampler?.volumesChanged = true } }

    func pageReloaded() { queue.async { self.sampler?.processes.resetIcons() } }

    func quit(key: String, force: Bool, reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async {
            guard let sampler = self.sampler else { return reply(false, "MacSense is still starting. Try again in a second.") }
            let result = sampler.processes.quit(key: key, force: force)
            reply(result.ok, result.message)
        }
    }

    /// Only a volume MacSense itself listed as ejectable can be ejected.
    func eject(path: String, reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async {
            guard let name = self.sampler?.volumes.ejectable[path] else {
                return reply(false, "That drive isn't mounted any more.")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
                    reply(true, "Ejected \(name). It's safe to unplug.")
                } catch {
                    reply(false, "Couldn't eject \(name): \(error.localizedDescription)")
                }
                self.volumesChanged()
            }
        }
    }
}
