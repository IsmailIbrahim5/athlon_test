import AVFoundation
import UIKit

class CameraManager {
    static let shared = CameraManager()
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isPrepared = false
    private var currentRecordingURL: URL?
    private var isPreWarmed = false
    
    private init() {
        // Start pre-warming when the manager is created
        preWarmCamera()
    }
    
    func preWarmCamera() {
        guard !isPreWarmed else { return }
        
        session = AVCaptureSession()
        session?.sessionPreset = .hd1920x1080
        
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        session?.beginConfiguration()
        if session?.canAddInput(input) == true {
            session?.addInput(input)
        }
        
        output = AVCaptureMovieFileOutput()
        if let output = output, session?.canAddOutput(output) == true {
            session?.addOutput(output)
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        session?.commitConfiguration()
        
        // Configure the session but don't start running
        isPreWarmed = true
    }

    func prepareCamera(completion: @escaping (Bool) -> Void) {
        if !isPreWarmed {
            preWarmCamera()
        }
        
        guard let session = session else {
            completion(false)
            return
        }
        
        DispatchQueue.global().async {
            session.startRunning()
            self.isPrepared = true
            DispatchQueue.main.async {
                completion(true)
            }
        }
    }

    func attachPreview(to view: UIView) {
        guard let previewLayer = previewLayer else { return }
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }
    
    func startRecording() -> URL? {
        guard let output = output, isPrepared else { return nil }
        
        let filename = "\(UUID().uuidString).mov"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        currentRecordingURL = outputURL
        
        output.startRecording(to: outputURL, recordingDelegate: self)
        return outputURL
    }

    func stopRecording() {
        output?.stopRecording()
    }
    
    func getCurrentRecordingPath() -> String? {
        return currentRecordingURL?.path
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("Recording error: \(error.localizedDescription)")
            return
        }
        print("Recording finished: \(outputFileURL.path)")
    }
}