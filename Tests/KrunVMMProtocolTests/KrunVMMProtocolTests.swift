import Foundation
import Testing

@testable import KrunVMMProtocol

@Test func configurationRoundTrips() throws {
  let original = KrunVMMConfig(
    libkrun: "/opt/container/libexec/container-plugins/container-krun-runtime/lib/libkrun.dylib",
    kernel: "/tmp/kernel",
    initDisk: "/tmp/init.ext4",
    rootDisk: "/tmp/root.ext4",
    commandLine: "console=hvc0 init=/sbin/vminitd ro root=/dev/vda",
    bootLog: "/tmp/boot.log",
    cpus: 3,
    memoryMiB: 1152,
    vsockMappings: [
      .init(port: 1024, path: "/tmp/vminit", listen: true),
      .init(port: 0x1000_0000, path: "/tmp/p00", listen: false),
    ],
    networks: [
      .init(
        ipv4Gateway: "192.168.200.1",
        ipv4Mask: "255.255.255.0",
        macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
      )
    ],
    disks: [
      .init(
        blockID: "volume0",
        path: "/tmp/volume.ext4",
        readOnly: false
      )
    ],
    virtioFS: [
      .init(
        tag: "krunfs0",
        path: "/tmp/share",
        readOnly: true
      )
    ]
  )
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(KrunVMMConfig.self, from: data)
  #expect(decoded == original)
}

@Test func networkConfigDefaultsToNoOffloadFlags() {
  let network = KrunNetworkConfig(
    ipv4Gateway: "192.168.200.1",
    ipv4Mask: "255.255.255.0",
    macAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
  )
  #expect(network.features == 0)
  #expect(network.flags == 0)
}

@Test func defaultsReserveControlAndStdioSeparately() {
  #expect(KrunDefaults.controlPort < KrunDefaults.firstIOPort)
  #expect(KrunDefaults.ioPortCount >= 3)
}

@Test func bundledLibkrunPathIsRelativeToPluginExecutable() {
  let executable = URL(
    fileURLWithPath:
      "/opt/container/libexec/container-plugins/container-krun-runtime/bin/container-krun-runtime"
  )
  #expect(
    KrunDefaults.bundledLibkrunPath(executableURL: executable)
      == "/opt/container/libexec/container-plugins/container-krun-runtime/lib/libkrun.dylib"
  )
}

@Test func nativeVMNetAcceptsBoundedStaticConfiguration() throws {
  #expect(KrunNetworkFeatures.nativeVMNetTCPOffload == 6531)
  let network = KrunNetworkConfig(
    ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0",
    macAddress: [2, 0, 0, 0, 0, 1],
    features: KrunNetworkFeatures.nativeVMNetTCPOffload
  )
  try network.validateNativeVMNet()
  let data = try JSONEncoder().encode(network)
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["socketPath"] == nil)
}

@Test func nativeVMNetRejectsInvalidMACAndPartialOffloads() {
  for mac: [UInt8] in [[], [2, 0], [0, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 1]] {
    let network = KrunNetworkConfig(
      ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0", macAddress: mac
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
  for (features, flags): (UInt32, UInt32) in [
    (1, 0), (1 << 11, 0),
    (KrunNetworkFeatures.nativeVMNetTCPOffload, 1),
  ] {
    let network = KrunNetworkConfig(
      ipv4Gateway: "192.168.200.1", ipv4Mask: "255.255.255.0",
      macAddress: [2, 0, 0, 0, 0, 1], features: features, flags: flags
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
}

@Test func nativeVMNetRejectsControlCharactersAndOversizedAddresses() {
  for gateway in [
    "192.168.1.1\u{0}evil", "192.168.1.1\n", "[::1]", String(repeating: "1", count: 16),
  ] {
    let network = KrunNetworkConfig(
      ipv4Gateway: gateway, ipv4Mask: "255.255.255.0", macAddress: [2, 0, 0, 0, 0, 1]
    )
    #expect(throws: KrunNativeVMNetError.self) { try network.validateNativeVMNet() }
  }
}

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Test func vmmControlChannelUsesStreamSocketPair() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  defer {
    try? pair.runtime.close()
    try? pair.helper.close()
  }

  for handle in [pair.runtime, pair.helper] {
    var socketType: Int32 = 0
    var length = socklen_t(MemoryLayout.size(ofValue: socketType))
    #expect(
      getsockopt(
        handle.fileDescriptor, SOL_SOCKET, SO_TYPE, &socketType, &length
      ) == 0
    )
    #expect(socketType == SOCK_STREAM)
  }
}

@Test func vmmControlChannelCanBackProcessStandardInput() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  let output = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/cat")
  process.standardInput = pair.helper
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice

  try process.run()
  try pair.helper.close()
  let payload = Data("control-stream\n".utf8)
  try pair.runtime.write(contentsOf: payload)
  #expect(shutdown(pair.runtime.fileDescriptor, SHUT_WR) == 0)
  process.waitUntilExit()

  let echoed = output.fileHandleForReading.readDataToEndOfFile()
  #expect(process.terminationStatus == 0)
  #expect(echoed == payload)
  try pair.runtime.close()
}

@Test func vmmControlChannelTransfersDialFileDescriptor() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  defer {
    try? pair.runtime.close()
    try? pair.helper.close()
  }

  try KrunVMMControlChannel.sendDialRequest(to: pair.runtime.fileDescriptor, port: 43210)
  #expect(
    try KrunVMMControlChannel.receiveRequest(from: pair.helper.fileDescriptor)
      == .dial(port: 43210)
  )

  let sourceFD = open("/dev/null", O_RDONLY)
  #expect(sourceFD >= 0)
  defer { close(sourceFD) }
  try KrunVMMControlChannel.sendDialResponse(
    to: pair.helper.fileDescriptor,
    result: 0,
    connectedFD: sourceFD
  )
  let received = try KrunVMMControlChannel.receiveDialResponse(from: pair.runtime.fileDescriptor)
  defer { try? received.close() }
  #expect(fcntl(received.fileDescriptor, F_GETFD) >= 0)
}

@Test func vmmControlChannelPreservesDialErrno() throws {
  let pair = try KrunVMMControlChannel.makeSocketPair()
  defer {
    try? pair.runtime.close()
    try? pair.helper.close()
  }

  try KrunVMMControlChannel.sendDialResponse(
    to: pair.helper.fileDescriptor,
    result: -ECONNREFUSED,
    connectedFD: nil
  )
  do {
    _ = try KrunVMMControlChannel.receiveDialResponse(from: pair.runtime.fileDescriptor)
    Issue.record("expected ECONNREFUSED")
  } catch let error as POSIXError {
    #expect(error.code == .ECONNREFUSED)
  }
}

@Test func vmmNamedControlSocketCarriesDialsFromOwner() throws {
  let directory = URL(fileURLWithPath: "/tmp/krun-ctl-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("vmm").path
  let listener = try KrunVMMControlChannel.listen(path: path)
  defer { try? listener.close() }

  var info = stat()
  #expect(stat(path, &info) == 0)
  #expect(info.st_mode & 0o077 == 0, "only the owner may connect")
  #expect(
    try KrunVMMControlChannel.accept(from: listener, timeoutMilliseconds: 10, peerUID: getuid())
      == nil, "no helper yet")

  let helperFD = try KrunVMMControlChannel.connect(path: path)
  defer { close(helperFD) }
  let runtime = try #require(
    try KrunVMMControlChannel.accept(from: listener, timeoutMilliseconds: 1000, peerUID: getuid()))
  defer { try? runtime.close() }

  try KrunVMMControlChannel.sendDialRequest(to: runtime.fileDescriptor, port: 7)
  #expect(try KrunVMMControlChannel.receiveRequest(from: helperFD) == .dial(port: 7))
  let sourceFD = open("/dev/null", O_RDONLY)
  defer { close(sourceFD) }
  try KrunVMMControlChannel.sendDialResponse(to: helperFD, result: 0, connectedFD: sourceFD)
  let received = try KrunVMMControlChannel.receiveDialResponse(from: runtime.fileDescriptor)
  defer { try? received.close() }
  #expect(fcntl(received.fileDescriptor, F_GETFD) >= 0)
}

@Test func vmmNamedControlSocketRejectsAnotherUser() throws {
  let directory = URL(fileURLWithPath: "/tmp/krun-ctl-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("vmm").path
  let listener = try KrunVMMControlChannel.listen(path: path)
  defer { try? listener.close() }
  let helperFD = try KrunVMMControlChannel.connect(path: path)
  defer { close(helperFD) }
  do {
    _ = try KrunVMMControlChannel.accept(
      from: listener, timeoutMilliseconds: 1000, peerUID: getuid() &+ 1)
    Issue.record("expected EPERM")
  } catch let error as POSIXError {
    #expect(error.code == .EPERM)
  }
}

@Test func configurationOmitsAbsentControlSocketPath() throws {
  let config = KrunVMMConfig(
    libkrun: "/l", kernel: "/k", initDisk: "/i", rootDisk: "/r", commandLine: "c", bootLog: "/b",
    cpus: 1, memoryMiB: 128, vsockMappings: [])
  let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
  #expect(!encoded.contains("controlSocketPath"))
  let withPath = KrunVMMConfig(
    libkrun: "/l", kernel: "/k", initDisk: "/i", rootDisk: "/r", commandLine: "c", bootLog: "/b",
    cpus: 1, memoryMiB: 128, vsockMappings: [], controlSocketPath: "/tmp/x/vmm")
  #expect(
    try JSONDecoder().decode(KrunVMMConfig.self, from: JSONEncoder().encode(withPath)) == withPath)
}
