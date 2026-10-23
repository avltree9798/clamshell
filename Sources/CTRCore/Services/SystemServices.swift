// SPDX-License-Identifier: GPL-3.0-or-later
//
// The services almost every application talks to at start-up. Command numbers
// and layouts from 3dbrew; behaviour is the minimum a homebrew or game needs.

/// srv: the service manager, the only port an application connects to directly.
final class ServiceManager: Service {
    private lazy var notificationSemaphore = KSemaphore(count: 0, maximum: 64)

    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x0001:  // RegisterClient
            ipc.reply([0])
        case 0x0002:  // EnableNotification
            ipc.reply([0], translate: IPC.handles([kernel.makeHandle(notificationSemaphore)]))
        case 0x0005:  // GetServiceHandle(name[8], length, flags)
            let length = Int(min(ipc[3], 8))
            var bytes: [UInt8] = []
            for i in 0..<length { bytes.append(UInt8(truncatingIfNeeded: ipc[1 + i / 4] >> UInt32((i % 4) * 8))) }
            let serviceName = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            let service: Service
            if let known = kernel.services[serviceName] {
                service = known
            } else if let make = kernel.makeStubService {
                service = make(serviceName)
                kernel.services[serviceName] = service
                kernel.record("srv: \(serviceName) is a stub")
            } else {
                ipc.reply([ResultCode.serviceNotRegistered])
                return
            }
            ipc.reply([0], translate: IPC.handles([kernel.makeHandle(KSession(service: service))], move: true))
        case 0x000B:  // ReceiveNotification
            ipc.reply([0, 0])
        case 0x000E:  // IsServiceRegistered
            ipc.reply([0, 1])
        default:
            ipc.reply([0])
        }
    }
}

/// APT: applet manager. An application only needs to be told it is running.
final class AppletService: Service {
    private let lock = KMutex()
    private lazy var notificationEvent = KEvent(resetType: .oneShot, name: "APT notification")
    private lazy var resumeEvent: KEvent = {
        let e = KEvent(resetType: .oneShot, name: "APT resume")
        e.signaled = true
        return e
    }()
    private var sentWakeup = false

    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x0001:  // GetLockHandle(attributes) -> attributes, state, lock
            ipc.reply([0, ipc[1], 0], translate: IPC.handles([kernel.makeHandle(lock)]))
        case 0x0002:  // Initialize(app id, attributes) -> notification and resume events
            ipc.reply([0], translate: IPC.handles([kernel.makeHandle(notificationEvent), kernel.makeHandle(resumeEvent)]))
        case 0x0009:  // IsRegistered
            ipc.reply([0, 1])
        case 0x000B:  // InquireNotification -> none
            ipc.reply([0, 0])
        case 0x000D, 0x000E:  // ReceiveParameter, GlanceParameter
            // The first parameter an application sees is "wake up" from the system.
            if !sentWakeup {
                if ipc.command == 0x000D { sentWakeup = true }
                ipc.reply([0, 0, 1, 0], translate: [0, 0])
            } else {
                ipc.reply([0xC880_CFFA])  // no parameter waiting
            }
        case 0x0043:  // NotifyToWait
            ipc.reply([0])
        case 0x004B:  // AppletUtility
            ipc.reply([0, 0])
        case 0x0050:  // GetApplicationCpuTimeLimit
            ipc.reply([0, 0])
        case 0x0101:  // IsNew3DS-style queries
            ipc.reply([0, 0])
        default:
            ipc.reply([0])
        }
    }
}

/// cfg: system settings. Language English, region Europe, an original 3DS.
final class ConfigService: Service {
    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x0001:  // GetConfigInfoBlk2(size, block id, buffer descriptor, pointer)
            let size = Int(min(ipc[1], 0x1000)), block = ipc[2], pointer = ipc[4]
            var data = [UInt8](repeating: 0, count: size)
            switch block {
            case 0x000A_0002: if size > 0 { data[0] = 1 }               // language: English
            case 0x000B_0000: if size > 3 { data[2] = 110; data[3] = 0 } // country: United Kingdom
            case 0x000A_0000:                                            // user name (UTF-16)
                for (i, c) in "Clamshell".utf16.enumerated() where i * 2 + 1 < size {
                    data[i * 2] = UInt8(c & 0xFF); data[i * 2 + 1] = UInt8(c >> 8)
                }
            case 0x0007_0001: if size > 0 { data[0] = 1 }               // sound output: stereo
            default: break
            }
            memory.writeBytes(pointer, data)
            ipc.reply([0])
        case 0x0002:  // SecureInfoGetRegion
            ipc.reply([0, 2])
        case 0x0003:  // GenHashConsoleUnique
            ipc.reply([0, 0x1234_5678, 0x9ABC_DEF0])
        case 0x0004:  // GetRegionCanadaUSA
            ipc.reply([0, 0])
        case 0x0005:  // GetSystemModel: original 3DS
            ipc.reply([0, 0])
        case 0x0006:  // GetModelNintendo2DS: 1 means not a 2DS
            ipc.reply([0, 1])
        default:
            unimplemented(ipc)
        }
    }
}

/// ptm: power. Always on mains with a full battery.
final class PowerService: Service {
    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x0005: ipc.reply([0, 1])  // GetAdapterState: charging
        case 0x0006: ipc.reply([0, 1])  // GetShellState: open
        case 0x0007: ipc.reply([0, 5])  // GetBatteryLevel
        case 0x0008: ipc.reply([0, 1])  // GetBatteryChargeState
        default: ipc.reply([0, 0])
        }
    }
}

/// fs: files. No archives yet: SD and save data report as absent.
final class FileSystemService: Service {
    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x0801, 0x0862:  // Initialize, SetPriority
            ipc.reply([0])
        case 0x0863:  // GetPriority
            ipc.reply([0, 0])
        case 0x0817, 0x0818:  // IsSdmcDetected, IsSdmcWritable
            ipc.reply([0, 0])
        case 0x080C, 0x0802, 0x0803:  // OpenArchive, OpenFileDirectly, OpenFile
            ipc.reply([0xC880_4478])  // not found
        default:
            unimplemented(ipc)
        }
    }
}
