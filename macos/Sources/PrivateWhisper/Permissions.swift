import AppKit
import AVFoundation

enum Permissions {
    /// Prompts for Accessibility if not yet granted. Returns current status.
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
