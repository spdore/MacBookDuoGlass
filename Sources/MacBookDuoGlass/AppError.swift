import Foundation

enum MacBookDuoGlassError: LocalizedError {
    case noBuiltInDisplay
    case screenCapturePermissionDenied
    case screenCaptureUnavailable(String)
    case metalUnavailable
    case sensorUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noBuiltInDisplay:
            return "没有找到 MacBook 内置显示器。"
        case .screenCapturePermissionDenied:
            return "没有屏幕录制权限。请在“系统设置 → 隐私与安全性 → 屏幕录制”中允许此应用。"
        case .screenCaptureUnavailable(let detail):
            return "屏幕采集不可用：\(detail)"
        case .metalUnavailable:
            return "当前 Mac 无法初始化 Metal 渲染器。"
        case .sensorUnavailable(let detail):
            return "开合角度传感器不可用：\(detail)"
        }
    }
}
