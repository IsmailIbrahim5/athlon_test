import Foundation
import AVFoundation

class VideoUploader: NSObject {
    static let shared = VideoUploader()
    private var uploadTasks: [String: URLSessionUploadTask] = [:]
    private var uploadProgress: [String: Double] = [:]
    private var uploadCompletion: [String: (String?, Error?) -> Void] = [:]
    private var eventSink: FlutterEventSink?
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.glitch.athlon_test.upload")
        config.isDiscretionary = true
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        super.init()
    }
    
    func uploadVideo(filePath: String, 
                    bucketId: String,
                    applicationKeyId: String,
                    applicationKey: String,
                    completion: @escaping (String?, Error?) -> Void) {
        
        // First, get the upload URL and authorization token
        let authString = "\(applicationKeyId):\(applicationKey)"
        let authData = authString.data(using: .utf8)!
        let base64Auth = authData.base64EncodedString()
        
        let getUploadUrl = "https://api.backblazeb2.com/b2api/v2/b2_get_upload_url"
        var request = URLRequest(url: URL(string: getUploadUrl)!)
        request.httpMethod = "POST"
        request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
        request.setValue(bucketId, forHTTPHeaderField: "X-Bz-Bucket-Id")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadUrl = json["uploadUrl"] as? String,
                  let authToken = json["authorizationToken"] as? String else {
                completion(nil, error ?? NSError(domain: "VideoUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get upload URL"]))
                return
            }
            
            // Now start the actual upload
            self.startUpload(filePath: filePath, 
                           uploadUrl: uploadUrl,
                           authToken: authToken,
                           completion: completion)
        }
        task.resume()
    }
    
    private func startUpload(filePath: String,
                           uploadUrl: String,
                           authToken: String,
                           completion: @escaping (String?, Error?) -> Void) {
        
        guard let fileURL = URL(fileURLWithPath: filePath) else {
            completion(nil, NSError(domain: "VideoUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file path"]))
            return
        }
        
        let fileName = fileURL.lastPathComponent
        let fileSize = try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64 ?? 0
        
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "POST"
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        request.setValue(fileName, forHTTPHeaderField: "X-Bz-File-Name")
        request.setValue("b2/x-auto", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        request.setValue(String(fileSize), forHTTPHeaderField: "X-Bz-Content-Sha1")
        
        let task = session.uploadTask(with: request, fromFile: fileURL)
        uploadTasks[filePath] = task
        uploadCompletion[filePath] = completion
        uploadProgress[filePath] = 0.0
        
        task.resume()
    }
    
    func cancelUpload(filePath: String) {
        uploadTasks[filePath]?.cancel()
        uploadTasks.removeValue(forKey: filePath)
        uploadCompletion.removeValue(forKey: filePath)
        uploadProgress.removeValue(forKey: filePath)
    }
    
    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
    }
}

extension VideoUploader: URLSessionTaskDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let filePath = uploadTasks.first(where: { $0.value == task })?.key else { return }
        
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        uploadProgress[filePath] = progress
        
        eventSink?([
            "type": "uploadProgress",
            "filePath": filePath,
            "progress": progress
        ])
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let filePath = uploadTasks.first(where: { $0.value == task })?.key else { return }
        
        if let error = error {
            uploadCompletion[filePath]?(nil, error)
        } else {
            // Get the file ID from the response
            if let response = task.response as? HTTPURLResponse,
               let responseData = task.originalRequest?.httpBody,
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let fileId = json["fileId"] as? String {
                uploadCompletion[filePath]?(fileId, nil)
            } else {
                uploadCompletion[filePath]?(nil, NSError(domain: "VideoUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get file ID"]))
            }
        }
        
        uploadTasks.removeValue(forKey: filePath)
        uploadCompletion.removeValue(forKey: filePath)
        uploadProgress.removeValue(forKey: filePath)
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
               let backgroundHandler = appDelegate.backgroundSessionCompletionHandler {
                backgroundHandler()
                appDelegate.backgroundSessionCompletionHandler = nil
            }
        }
    }
} 