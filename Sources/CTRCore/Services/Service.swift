// SPDX-License-Identifier: GPL-3.0-or-later

/// The IPC command buffer of the calling thread (TLS + 0x80).
///
/// Word 0 is the header: command id << 16 | normal word count << 6 | translate word count.
/// Replies reuse the buffer: header, result code, normal words, then translate words.
struct IPC {
    let memory: AddressSpace
    let address: UInt32

    var header: UInt32 { memory.read32(address) }
    var command: UInt32 { header >> 16 }

    subscript(i: Int) -> UInt32 {
        get { memory.read32(address &+ UInt32(i * 4)) }
        nonmutating set { memory.write32(address &+ UInt32(i * 4), newValue) }
    }

    /// Writes a reply. `normal` starts with the result code.
    func reply(_ normal: [UInt32], translate: [UInt32] = []) {
        self[0] = command << 16 | UInt32(normal.count) << 6 | UInt32(translate.count)
        for (i, w) in normal.enumerated() { self[1 + i] = w }
        for (i, w) in translate.enumerated() { self[1 + normal.count + i] = w }
    }

    /// Translate words that pass handles: a descriptor, then the handles.
    static func handles(_ handles: [UInt32], move: Bool = false) -> [UInt32] {
        [UInt32(handles.count - 1) << 26 | (move ? 0x10 : 0)] + handles
    }

    /// Pointer from a buffer-mapping descriptor pair starting at word `i`, as libctru builds them.
    func bufferPointer(at i: Int) -> UInt32 { self[i + 1] }
}

/// An HLE system service, reached through srv:GetServiceHandle.
class Service {
    let name: String
    unowned let kernel: Kernel
    private var reported: Set<UInt32> = []

    init(name: String, kernel: Kernel) {
        self.name = name
        self.kernel = kernel
    }

    var memory: AddressSpace { kernel.memory }

    /// Handles one request. The default accepts any command and returns success.
    func handle(_ ipc: inout IPC) {
        unimplemented(ipc)
    }

    /// Replies success with no data and logs the command once, so unknown calls are visible.
    func unimplemented(_ ipc: IPC) {
        if reported.insert(ipc.command).inserted {
            kernel.record("\(name): unimplemented command 0x\(String(ipc.header, radix: 16))")
        }
        ipc.reply([ResultCode.success])
    }
}

/// A service nobody implemented yet: every command succeeds with no outputs.
final class StubService: Service {}
