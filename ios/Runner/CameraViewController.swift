import UIKit
import AVFoundation

class CameraViewController: UIViewController {
    private let previewView = UIView()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let cameraManager = CameraManager.shared
    private var isRecording = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupCamera()
    }
    
    private func setupCamera() {
        cameraManager.prepareCamera { [weak self] success in
            guard let self = self else { return }
            if success {
                self.cameraManager.attachPreview(to: self.previewView)
            } else {
                self.showError(message: "Failed to setup camera")
            }
        }
    }

    private func setupUI() {
        view.backgroundColor = .black

        // Setup preview
        previewView.frame = view.bounds
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(previewView)

        // Start Button
        startButton.setTitle("Start", for: .normal)
        startButton.backgroundColor = .systemGreen
        startButton.setTitleColor(.white, for: .normal)
        startButton.layer.cornerRadius = 25
        startButton.addTarget(self, action: #selector(startRecording), for: .touchUpInside)
        startButton.frame = CGRect(x: 50, y: view.bounds.height - 100, width: 100, height: 50)
        view.addSubview(startButton)

        // Stop Button
        stopButton.setTitle("Stop", for: .normal)
        stopButton.backgroundColor = .systemRed
        stopButton.setTitleColor(.white, for: .normal)
        stopButton.layer.cornerRadius = 25
        stopButton.addTarget(self, action: #selector(stopRecording), for: .touchUpInside)
        stopButton.frame = CGRect(x: 200, y: view.bounds.height - 100, width: 100, height: 50)
        stopButton.isEnabled = false
        view.addSubview(stopButton)
    }

    @objc private func startRecording() {
        guard let _ = cameraManager.startRecording() else {
            showError(message: "Failed to start recording")
            return
        }
        
        isRecording = true
        startButton.isEnabled = false
        stopButton.isEnabled = true
    }

    @objc private func stopRecording() {
        cameraManager.stopRecording()
        isRecording = false
        startButton.isEnabled = true
        stopButton.isEnabled = false
    }
    
    private func showError(message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}