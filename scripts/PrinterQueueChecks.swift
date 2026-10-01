import Foundation

actor ScriptedQueue {
    struct Step: Sendable {
        let path: String
        let arguments: [String]
        let result: PrintCommand.Result
    }
    var steps: [Step]
    init(_ steps: [Step]) { self.steps = steps }
    func run(_ path: String, _ arguments: [String]) throws -> PrintCommand.Result {
        guard let step = steps.first, step.path == path, step.arguments == arguments else {
            fatalError("Unexpected printer operation: \(path) \(arguments)")
        }
        steps.removeFirst()
        return step.result
    }
    func verify() {
        precondition(steps.isEmpty, "Expected operations were not run")
    }
}

@main
struct PrinterQueueChecks {
    static let id = "Test_Printer"
    static let idle = "printer Test_Printer is idle.  enabled since Thu Oct  1 09:49:42 2026\n\tForm mounted:\n"
    static let paused = "printer Test_Printer disabled since Tue Sep 29 12:01:20 2026 -\n\tUnable to add document to print job.\n\tForm mounted:\n"
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: \(message)")
    }
    static func status(_ output: String, code: Int32 = 0) -> ScriptedQueue.Step {
        .init(path: "/usr/bin/lpstat", arguments: ["-l", "-p", id], result: .init(status: code, output: output))
    }
    static func resume(code: Int32 = 0) -> ScriptedQueue.Step {
        .init(path: "/usr/sbin/cupsenable", arguments: [id], result: .init(status: code, output: ""))
    }
    static func main() async throws {
        let stopped = try PrinterQueueStatus(output: paused, printerID: id)
        check(stopped.isPaused && stopped.reason == "Unable to add document to print job.", "Paused queue preserves its error")
        check(try !PrinterQueueStatus(output: idle, printerID: id).isPaused, "Idle enabled queue is recognized")
        check(try !PrinterQueueStatus(output: "printer Test_Printer now printing Test_Printer-42.  enabled since today", printerID: id).isPaused, "Active queue is recognized")
        for invalid in ["", "printer Other disabled since today", "printer Test_Printer is idle.", "printer Test_Printer unexpected state", "lpstat: printer not found"] {
            do {
                _ = try PrinterQueueStatus(output: invalid, printerID: id)
                fatalError("Unrecognized queue must fail closed")
            } catch { print("PASS: Unknown or wrong queue is rejected") }
        }
        let success = ScriptedQueue([status(paused), resume(), status(idle)])
        let updated = try await PrinterQueueService.resume(id, run: { try await success.run($0, $1) })
        check(!updated.isPaused, "Resume checks state before and after enabling only the selected queue")
        await success.verify()

        let active = ScriptedQueue([status(idle)])
        _ = try await PrinterQueueService.resume(id, run: { try await active.run($0, $1) })
        await active.verify()
        print("PASS: Already enabled queue requires no mutation")

        for (name, steps) in [
            ("Read failure never enables queue", [status("unavailable", code: 1)]),
            ("Unrecognized state never enables queue", [status("unexpected")]),
            ("Permission failure is reported without retries", [status(paused), resume(code: 1)]),
            ("Persistent pause is reported without a retry loop", [status(paused), resume(), status(paused)]),
            ("Failed verification is not reported as resumed", [status(paused), resume(), status("unavailable", code: 1)])
        ] {
            let fake = ScriptedQueue(steps)
            do {
                _ = try await PrinterQueueService.resume(id, run: { try await fake.run($0, $1) })
                fatalError(name)
            } catch { print("PASS: \(name)") }
            await fake.verify()
        }
        print("Queue recovery checks passed. All printer operations were simulated.")
    }
}
