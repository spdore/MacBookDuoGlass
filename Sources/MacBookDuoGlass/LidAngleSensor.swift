import Foundation
import IOKit.hid
import QuartzCore

final class LidAngleSensor {
    typealias SampleHandler = (AngleSample) -> Void

    private let queue = DispatchQueue(label: "com.spdor.MacBookDuoGlass.lid-angle", qos: .userInitiated)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private var handler: SampleHandler?
    private var isRunning = false
    private var lastSuccessfulRead = CACurrentMediaTime()

    func start(handler: @escaping SampleHandler) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handler = handler
            self.isRunning = true
            self.discoverDeviceIfNeeded()
            self.installTimer()
            self.readAndPublish()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            if let device = self.device {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            self.device = nil
            if let manager = self.manager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            self.manager = nil
        }
    }

    private func installTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            self?.readAndPublish()
        }
        self.timer = timer
        timer.resume()
    }

    private func discoverDeviceIfNeeded() {
        guard device == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // AppleSPUHIDDevice exposes the lid sensor as a vendor HID sensor:
        // VID 0x05AC, PID 0x8104, sensor page 0x0020, usage 0x008A.
        let matching: CFDictionary = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDPrimaryUsagePageKey as String: 0x0020,
            kIOHIDPrimaryUsageKey as String: 0x008A
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }

        guard let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 else {
            return
        }

        let count = CFSetGetCount(devices)
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        defer { values.deallocate() }
        CFSetGetValues(devices, values)

        for index in 0..<count {
            guard let pointer = values[index] else { continue }
            let candidate = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                continue
            }

            var report = [UInt8](repeating: 0, count: 8)
            var length = report.count
            let result = report.withUnsafeMutableBytes { bytes in
                IOHIDDeviceGetReport(
                    candidate,
                    kIOHIDReportTypeFeature,
                    CFIndex(1),
                    bytes.bindMemory(to: UInt8.self).baseAddress!,
                    &length
                )
            }

            if result == kIOReturnSuccess, length >= 3 {
                self.device = candidate
                return
            }
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func readAndPublish() {
        guard isRunning else { return }
        if device == nil {
            discoverDeviceIfNeeded()
        }

        guard let device else {
            if CACurrentMediaTime() - lastSuccessfulRead > 0.25 {
                publish(.init(degrees: 0, rawValue: 0, timestamp: CACurrentMediaTime(), isValid: false))
            }
            return
        }

        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        let result = report.withUnsafeMutableBytes { bytes in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(1),
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                &length
            )
        }

        guard result == kIOReturnSuccess, length >= 3 else {
            if CACurrentMediaTime() - lastSuccessfulRead > 0.25 {
                publish(.init(degrees: 0, rawValue: 0, timestamp: CACurrentMediaTime(), isValid: false))
            }
            return
        }

        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        lastSuccessfulRead = CACurrentMediaTime()

        // Firmware seen in the wild reports either degrees or hundredths of a
        // degree. The value range lets us choose safely for this sensor.
        let degrees: Double
        if raw == 1 {
            degrees = 0
        } else if raw > 360 {
            degrees = Double(raw) / 100.0
        } else {
            degrees = Double(raw)
        }

        publish(.init(
            degrees: min(max(degrees, 0), 180),
            rawValue: raw,
            timestamp: lastSuccessfulRead,
            isValid: true
        ))
    }

    private func publish(_ sample: AngleSample) {
        let handler = handler
        DispatchQueue.main.async {
            handler?(sample)
        }
    }
}
