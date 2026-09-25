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
    private var consecutiveReadFailures = 0
    private var nextDiscoveryAttempt = -Double.greatestFiniteMagnitude
    private var hasPublishedInvalidSample = false
    // Owned by the serial sensor queue; reuse storage for every HID request.
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)

    deinit {
        reportBuffer.deallocate()
    }
    // Keep one pending sample
    // and deliver only the newest value to AppKit so stale angles cannot pile
    // up on the main queue.
    private let deliveryLock = NSLock()
    private var pendingSample: AngleSample?
    private var deliveryScheduled = false
    private var deliveryGeneration: UInt = 0
    private var lastQueuedRawValue: UInt16?
    private var lastQueuedValidity: Bool?

    private let invalidReadTimeout: CFTimeInterval = 0.25
    private let discoveryRetryInterval: CFTimeInterval = 0.25
    private let failuresBeforeReconnect = 3
    // The renderer is locked to 60 Hz, so reading the lid sensor at the same
    // cadence avoids waking the CPU several times for a value that cannot be
    // displayed until the next refresh.
    private let sampleInterval: DispatchTimeInterval = .microseconds(16_667)

    func start(handler: @escaping SampleHandler) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handler = handler
            self.isRunning = true
            self.lastSuccessfulRead = CACurrentMediaTime()
            self.consecutiveReadFailures = 0
            self.hasPublishedInvalidSample = false
            self.nextDiscoveryAttempt = -Double.greatestFiniteMagnitude
            self.deliveryLock.lock()
            self.deliveryGeneration &+= 1
            self.pendingSample = nil
            self.deliveryScheduled = false
            self.lastQueuedRawValue = nil
            self.lastQueuedValidity = nil
            self.deliveryLock.unlock()
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
            self.closeSensorResources()
            self.deliveryLock.lock()
            self.deliveryGeneration &+= 1
            self.pendingSample = nil
            self.deliveryScheduled = false
            self.lastQueuedRawValue = nil
            self.lastQueuedValidity = nil
            self.deliveryLock.unlock()
        }
    }

    private func installTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: sampleInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.readAndPublish()
        }
        self.timer = timer
        timer.resume()
    }

    private func discoverDeviceIfNeeded() {
        guard device == nil else { return }

        let now = CACurrentMediaTime()
        guard now >= nextDiscoveryAttempt else { return }
        nextDiscoveryAttempt = now + discoveryRetryInterval

        // A manager with no device can also become stale across sleep. Close
        // it before creating a fresh one so the next attempt sees the
        // post-wake HID device set and does not leak managers every 5 ms.
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }

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
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
            return
        }

        guard let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
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
                self.consecutiveReadFailures = 0
                self.lastSuccessfulRead = now
                self.hasPublishedInvalidSample = false
                return
            }
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func readAndPublish() {
        guard isRunning else { return }
        if device == nil {
            discoverDeviceIfNeeded()
        }

        guard let device else {
            publishInvalidIfNeeded()
            return
        }

        var length = 8
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, CFIndex(1), reportBuffer, &length)

        guard result == kIOReturnSuccess, length >= 3 else {
            consecutiveReadFailures += 1
            if consecutiveReadFailures >= failuresBeforeReconnect {
                closeSensorResources()
                nextDiscoveryAttempt = CACurrentMediaTime() + discoveryRetryInterval
            }
            publishInvalidIfNeeded()
            return
        }

        let raw = UInt16(reportBuffer[1]) | (UInt16(reportBuffer[2]) << 8)
        lastSuccessfulRead = CACurrentMediaTime()
        consecutiveReadFailures = 0
        hasPublishedInvalidSample = false

        // Always refresh device health above, including after a read failure.
        // Unchanged valid reports need no conversion, sample or delivery work.
        guard lastQueuedValidity != true || lastQueuedRawValue != raw else { return }

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

    private func publishInvalidIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastSuccessfulRead > invalidReadTimeout,
              !hasPublishedInvalidSample else { return }
        hasPublishedInvalidSample = true
        publish(.init(degrees: 0, rawValue: 0, timestamp: now, isValid: false))
    }

    private func closeSensorResources() {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        self.device = nil
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        self.manager = nil
    }

    private func publish(_ sample: AngleSample) {
        guard lastQueuedRawValue != sample.rawValue || lastQueuedValidity != sample.isValid else {
            return
        }
        lastQueuedRawValue = sample.rawValue
        lastQueuedValidity = sample.isValid

        let handler = handler
        deliveryLock.lock()
        pendingSample = sample
        guard !deliveryScheduled else {
            deliveryLock.unlock()
            return
        }
        deliveryScheduled = true
        let generation = deliveryGeneration
        deliveryLock.unlock()

        DispatchQueue.main.async {
            self.deliveryLock.lock()
            guard self.deliveryScheduled,
                  self.deliveryGeneration == generation else {
                self.deliveryLock.unlock()
                return
            }
            let newestSample = self.pendingSample
            self.pendingSample = nil
            self.deliveryScheduled = false
            self.deliveryLock.unlock()
            guard let newestSample else { return }
            handler?(newestSample)
        }
    }
}
