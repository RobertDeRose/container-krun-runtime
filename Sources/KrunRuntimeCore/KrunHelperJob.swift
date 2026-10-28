import ContainerizationError
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// The VMM helper, run as its own launchd job in the caller's session.
///
/// Apple Container starts runtime plugins as Standard launchd jobs, whose
/// scheduling clamp every child inherits: a helper spawned directly by the
/// plugin runs its vCPU and device threads below ordinary user work and is
/// starved whenever the host is busy. Apple's own VM process escapes the clamp
/// because launchd spawns it as an XPC service. A job with ProcessType
/// Interactive gets the same treatment, so the helper is started that way.
final class KrunHelperJob: @unchecked Sendable {
  static let labelPrefix = "com.github.robertderose.container-krun-runtime.vmm."

  let label: String
  private let domain: String
  private let lock = NSLock()
  private var cachedPID: pid_t = 0

  private init(label: String, domain: String) {
    self.label = label
    self.domain = domain
  }

  /// Process ID of the job (sudo for the native helper), 0 until launchd reports one.
  var processIdentifier: pid_t {
    lock.lock()
    defer { lock.unlock() }
    if cachedPID == 0 {
      cachedPID = Self.runningPID(domain: domain, label: label) ?? 0
    }
    return cachedPID
  }

  var isRunning: Bool {
    let pid = processIdentifier
    guard pid > 0 else {
      // launchd has not reported a PID yet: the job is still starting, or exited.
      return Self.runningPID(domain: domain, label: label) != nil
    }
    // The native job runs as root; EPERM still means the process exists.
    return kill(pid, 0) == 0 || errno == EPERM
  }

  static func label(forContainer id: String) -> String {
    let safe = id.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        ? Character(scalar) : "_"
    }
    return labelPrefix + String(safe)
  }

  /// Write a job description for arguments and start it in the caller's GUI
  /// session. A stale job with the same label, left by a plugin that died
  /// without stopping it, is removed first.
  static func launch(
    label: String,
    arguments: [String],
    environment: [String: String]?,
    logPath: String,
    plistPath: URL
  ) throws -> KrunHelperJob {
    let domain = "gui/\(getuid())"
    _ = launchctl(["bootout", "\(domain)/\(label)"])
    var job: [String: Any] = [
      "Label": label,
      "ProgramArguments": arguments,
      "ProcessType": "Interactive",
      "RunAtLoad": true,
      "StandardOutPath": logPath,
      "StandardErrorPath": logPath,
      // Matches the earlier SIGTERM-then-SIGKILL grace period.
      "ExitTimeOut": 5,
    ]
    if let environment {
      job["EnvironmentVariables"] = environment
    }
    let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    try data.write(to: plistPath, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistPath.path)
    let result = launchctl(["bootstrap", domain, plistPath.path])
    guard result.status == 0 else {
      throw ContainerizationError(
        .internalError,
        message: "launchctl bootstrap \(label) failed (\(result.status)): \(result.output)"
      )
    }
    return KrunHelperJob(label: label, domain: domain)
  }

  /// Remove the job; launchd sends SIGTERM and, after ExitTimeOut, SIGKILL.
  func stop() {
    _ = Self.launchctl(["bootout", "\(domain)/\(label)"])
    // bootout returns before the process is reaped, typically by about 10 ms.
    for _ in 0..<1200 where isRunning {
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  private static func runningPID(domain: String, label: String) -> pid_t? {
    let result = launchctl(["print", "\(domain)/\(label)"])
    guard result.status == 0 else { return nil }
    for line in result.output.split(separator: "\n") {
      let fields = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if fields.count == 2, fields[0] == "pid", let pid = pid_t(fields[1]), pid > 0 {
        return pid
      }
    }
    return nil
  }

  /// Run launchctl with posix_spawn. Foundation's Process costs about 65 ms per
  /// launch, which every container start and stop would otherwise pay per call.
  @discardableResult
  private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return (-1, "pipe failed: errno \(errno)") }
    let (readFD, writeFD) = (fds[0], fds[1])
    defer { close(readFD) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Pass only the three standard descriptors; the runtime holds control sockets.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    let argv = (["/bin/launchctl"] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, "/bin/launchctl", &actions, &attributes, argv, environ)
    close(writeFD)
    guard spawned == 0 else { return (-1, "posix_spawn launchctl failed: errno \(spawned)") }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(readFD, &buffer, buffer.count)
      if count > 0 {
        output.append(contentsOf: buffer[0..<count])
      } else if count == 0 || errno != EINTR {
        break
      }
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    return (exitStatus, String(decoding: output, as: UTF8.self))
  }
}
