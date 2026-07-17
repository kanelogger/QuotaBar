import Darwin
import Foundation

func terminateAndReap(_ process: Process, grace: TimeInterval = 0.5) {
    guard process.isRunning else {
        process.waitUntilExit()
        return
    }

    process.terminate()
    let deadline = Date().addingTimeInterval(grace)
    while process.isRunning, Date() < deadline {
        usleep(25_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}
