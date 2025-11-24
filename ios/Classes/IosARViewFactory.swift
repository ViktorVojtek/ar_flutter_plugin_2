import Flutter
import UIKit

class IosARViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        // ✅ Use RealityKit implementation (iOS 13.0+)
        if #available(iOS 13.0, *) {
            return IosARViewRealityKit(
                frame: frame,
                viewIdentifier: viewId,
                arguments: args,
                binaryMessenger: messenger)
        } else {
            // Fallback to SceneKit for older iOS versions (should not happen in practice)
            return IosARView(
                frame: frame,
                viewIdentifier: viewId,
                arguments: args,
                binaryMessenger: messenger)
        }
    }
}
