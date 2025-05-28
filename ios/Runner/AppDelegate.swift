import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "com.glitch.athlon_test"
  private var peerManager: PeerManager?
  var backgroundSessionCompletionHandler: (() -> Void)?
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let connectionChannel = FlutterMethodChannel(name: channelName,
                                              binaryMessenger: controller.binaryMessenger)
    let eventChannel = FlutterEventChannel(name: "\(channelName)/events", binaryMessenger: controller.binaryMessenger)
    let uploadEventChannel = FlutterEventChannel(name: "\(channelName)/upload_events", binaryMessenger: controller.binaryMessenger)
    
    peerManager = PeerManager()
    eventChannel.setStreamHandler(peerManager)
    uploadEventChannel.setStreamHandler(VideoUploader.shared)

    connectionChannel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
          guard let self = self, let peerManager = self.peerManager else {
            result(FlutterError(code: "INITIALIZATION_ERROR", message: "PeerManager not initialized", details: nil))
            return
          }
          
          switch call.method {
          case "searchPeers":
            peerManager.startBrowsing(completion: { peers in
              result(peers)
            })

          case "connectPeer":
            if let args = call.arguments as? [String: Any], let peerId = args["peerId"] as? String {
              peerManager.connectToPeer(withId: peerId, completion: { success in
                result(success)
              })
            } else {
              result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing peerId", details: nil))
            }

          case "scheduleRecord":
            if let args = call.arguments as? [String: Any], let delay = args["delay"] as? Double {
                let cameraVC = CameraViewController()
                controller.present(cameraVC, animated: true)
                peerManager.scheduleRecording(after: delay, completion: { filePath in
                    result(filePath)
                })
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing delay", details: nil))
            }

          case "uploadVideo":
            if let args = call.arguments as? [String: Any],
               let filePath = args["filePath"] as? String,
               let bucketId = args["bucketId"] as? String,
               let applicationKeyId = args["applicationKeyId"] as? String,
               let applicationKey = args["applicationKey"] as? String {
                
                VideoUploader.shared.uploadVideo(
                    filePath: filePath,
                    bucketId: bucketId,
                    applicationKeyId: applicationKeyId,
                    applicationKey: applicationKey
                ) { fileId, error in
                    if let error = error {
                        result(FlutterError(code: "UPLOAD_ERROR",
                                          message: error.localizedDescription,
                                          details: nil))
                    } else {
                        result(fileId)
                    }
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT",
                                  message: "Missing required upload parameters",
                                  details: nil))
            }

          case "cancelUpload":
            if let args = call.arguments as? [String: Any],
               let filePath = args["filePath"] as? String {
                VideoUploader.shared.cancelUpload(filePath: filePath)
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT",
                                  message: "Missing filePath",
                                  details: nil))
            }

          default:
            result(FlutterMethodNotImplemented)
          }
        })

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  override func application(_ application: UIApplication,
                          handleEventsForBackgroundURLSession identifier: String,
                          completionHandler: @escaping () -> Void) {
    backgroundSessionCompletionHandler = completionHandler
  }
}
