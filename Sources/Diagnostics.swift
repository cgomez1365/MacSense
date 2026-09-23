import Foundation

/// Headless modes, for checking MacSense's numbers against the system's own tools.
enum Diagnostics {
    /// `MacSense --dump --count N` prints N samples, one second apart, as JSON lines.
    static func dump(count: Int) {
        let sampler = Sampler(includeIcons: false)
        sampler.prime()
        for index in 0..<max(1, count) {
            Thread.sleep(forTimeInterval: 1)
            var sample = sampler.sample(everything: true)
            if index == 0 { sample["info"] = SystemInfo.collect() }
            if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                print("{\"error\":\"this sample could not be encoded as JSON\"}")
            }
            fflush(stdout)
        }
    }

    /// `MacSense --smc-probe` lists which fan and temperature keys this Mac answers.
    static func smcProbe() {
        guard ms_smc_open() else { return print("AppleSMC: not available on this Mac") }
        let candidates = ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F1Ac", "TC0D", "TC0E", "TC0F", "TC0P", "TC0H",
                          "TCXC", "TC1C", "TC2C", "TG0D", "TG0P", "TG0H", "TGDD", "TA0P", "TA0p", "Tm0P", "TH0P",
                          "Ts0P", "Tp09", "Tp0T", "Tp01", "Tg0T", "Tg05"]
        for key in candidates {
            var value = 0.0
            if ms_smc_read(key, &value) { print("\(key)  \(value)") }
        }
        ms_smc_close()
    }
}
