import Foundation
import MultipeerConnectivity
import AVFoundation
import MachO

class PeerManager: NSObject {
  private let serviceType = "record-sync"
  private let myPeerId = MCPeerID(displayName: UIDevice.current.name)
  private var session: MCSession!
  private var advertiser: MCNearbyServiceAdvertiser!
  private var browser: MCNearbyServiceBrowser?
  private var discoveredPeers: [MCPeerID] = []
  private var connectedPeer: MCPeerID?
  private var eventSink: FlutterEventSink?
  
  // Time synchronization
  private var offsets: [Double] = []
  private var pingCount = 0
  private var calculatedOffset: Double?
  private var pingStartTime: UInt64?
  private let maxPingCount = 200  // Increased samples for better accuracy
  private let pingInterval = 0.02 // 20ms interval for more frequent updates
  private var timebaseInfo: mach_timebase_info = mach_timebase_info()
  private let requiredPrecision = 1.0/30.0/2.0 // Half a frame at 30fps (16.67ms)
  private var lastSyncTime: UInt64 = 0
  private let syncInterval: UInt64 = 1_000_000_000 // 1 second in nanoseconds
  
  // Camera
  private let cameraManager = CameraManager.shared
  private var recordingCompletion: ((String) -> Void)?

  private var timeOffset: TimeInterval = 0
  private var pingLoop = true

  override init() {
    super.init()
    mach_timebase_info(&timebaseInfo)
    setupSession()
  }

  private func setupSession() {
    session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
    session.delegate = self
    
    advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
    advertiser.delegate = self
    advertiser.startAdvertisingPeer()
  }

  func startBrowsing(completion: @escaping ([String]) -> Void) {
    browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
    browser?.delegate = self
    browser?.startBrowsingForPeers()
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      completion(self.discoveredPeers.map { $0.displayName })
    }
  }

  func connectToPeer(withId id: String, completion: @escaping (Bool) -> Void) {
    guard let peer = discoveredPeers.first(where: { $0.displayName == id }) else {
      completion(false)
      return
    }
    
    browser?.invitePeer(peer, to: session, withContext: nil, timeout: 10)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
      completion(self.session.connectedPeers.contains(peer))
    }
  }

  func scheduleRecording(after delay: TimeInterval, completion: @escaping (String) -> Void) {
    guard let peer = connectedPeer, let offset = calculatedOffset else {
      completion("")
      return
    }
    
    // Verify we have sub-frame accuracy before proceeding
    let currentPrecision = calculateCurrentPrecision()
    guard currentPrecision <= requiredPrecision else {
      print("Warning: Current precision (\(currentPrecision)s) is not sub-frame accurate")
      completion("")
      return
    }
    
    recordingCompletion = completion
    pingLoop = false
    
    // Add a small buffer time (50ms) to ensure both devices are ready
    let bufferTime: TimeInterval = 0.05
    
    cameraManager.prepareCamera { [weak self] success in
      guard let self = self, success else {
        completion("")
        return
      }
      
      let now = machToSeconds(mach_absolute_time())
      let scheduledLocalStart = now + delay + bufferTime
      let scheduledPeerStart = scheduledLocalStart + offset
      
      let message = [
        "type": "startRecording",
        "startAt": scheduledPeerStart,
        "precision": currentPrecision
      ] as [String: Any]
      
      do {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        try self.session.send(data, toPeers: [peer], with: .reliable)
        
        // Schedule local recording
        let timeUntilStart = scheduledLocalStart - now
        DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilStart) {
          if let path = self.cameraManager.startRecording()?.path {
            self.recordingCompletion?(path)
          }
        }
      } catch {
        print("Failed to send start signal: \(error)")
        completion("")
      }
    }
  }

  func stopRecording() {
    cameraManager.stopRecording()
    
    if let peer = connectedPeer {
      let message = ["type": "stopRecording"]
      if let data = try? JSONSerialization.data(withJSONObject: message, options: []) {
        try? session.send(data, toPeers: [peer], with: .reliable)
      }
    }
  }

  private func machToSeconds(_ machTime: UInt64) -> Double {
    return Double(machTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000_000.0
  }

  private func secondsToMach(_ seconds: Double) -> UInt64 {
    return UInt64(seconds * 1_000_000_000.0 * Double(timebaseInfo.denom) / Double(timebaseInfo.numer))
  }

  private func sendTimePing() {
    guard let peer = connectedPeer else { return }
    
    let currentTime = mach_absolute_time()
    let message = [
      "type": "timePing",
      "time": currentTime
    ] as [String: Any]
    
    do {
      let data = try JSONSerialization.data(withJSONObject: message, options: [])
      try session.send(data, toPeers: [peer], with: .reliable)
      pingStartTime = currentTime
    } catch {
      print("Failed to send time ping: \(error)")
    }
  }

  private func handleTimePing(_ json: [String: Any]) {
    guard let peer = connectedPeer,
          let theirTime = json["time"] as? UInt64 else { return }
    
    let currentTime = mach_absolute_time()
    let response = [
      "type": "timePong",
      "theirTime": theirTime,
      "myTime": currentTime
    ] as [String: Any]
    
    do {
      let data = try JSONSerialization.data(withJSONObject: response, options: [])
      try session.send(data, toPeers: [peer], with: .reliable)
    } catch {
      print("Failed to send time pong: \(error)")
    }
  }

  private func handleTimePong(_ json: [String: Any]) {
    guard let theirTime = json["theirTime"] as? UInt64,
          let theirResponseTime = json["myTime"] as? UInt64,
          let startTime = pingStartTime else { return }
    
    let receiveTime = mach_absolute_time()
    
    // Convert mach times to seconds for calculation
    let t1 = machToSeconds(theirTime)
    let t2 = machToSeconds(theirResponseTime)
    let t3 = machToSeconds(receiveTime)
    let t0 = machToSeconds(startTime)
    
    // NTP-like calculation with improved precision
    let rtt = t3 - t0
    let oneWay = rtt / 2.0
    let offset = ((t2 - t1) + (t3 - t0)) / 2.0
    
    // Enhanced outlier filtering
    if pingCount > 0 {
      let mean = offsets.reduce(0, +) / Double(offsets.count)
      let stdDev = sqrt(offsets.map { pow($0 - mean, 2) }.reduce(0, +) / Double(offsets.count))
      
      // More aggressive outlier filtering for sub-frame accuracy
      if abs(offset - mean) > requiredPrecision {
        print("Filtered out outlier offset: \(offset)")
        return
      }
    }
    
    offsets.append(offset)
    pingCount += 1
    
    // Calculate current precision
    let currentPrecision = calculateCurrentPrecision()
    
    eventSink?([
      "ping": pingCount,
      "offset": offset,
      "RTT": rtt,
      "precision": currentPrecision,
      "isSubFrame": currentPrecision <= requiredPrecision
    ])
    
    if pingCount >= maxPingCount {
      // Use trimmed mean for final offset (remove top and bottom 10%)
      let sortedOffsets = offsets.sorted()
      let trimCount = Int(Double(sortedOffsets.count) * 0.1)
      let trimmedOffsets = sortedOffsets[trimCount..<(sortedOffsets.count - trimCount)]
      calculatedOffset = trimmedOffsets.reduce(0, +) / Double(trimmedOffsets.count)
      
      print("Final calculated offset: \(calculatedOffset!) seconds")
      print("Final precision: \(currentPrecision) seconds")
      print("Is sub-frame accurate: \(currentPrecision <= requiredPrecision)")
      
      // Start periodic re-synchronization
      startPeriodicSync()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + pingInterval) {
        self.sendTimePing()
      }
    }
  }

  private func calculateCurrentPrecision() -> Double {
    guard offsets.count > 1 else { return Double.infinity }
    
    // Calculate standard deviation of recent offsets
    let recentOffsets = Array(offsets.suffix(min(20, offsets.count)))
    let mean = recentOffsets.reduce(0, +) / Double(recentOffsets.count)
    let variance = recentOffsets.map { pow($0 - mean, 2) }.reduce(0, +) / Double(recentOffsets.count)
    return sqrt(variance)
  }

  private func startPeriodicSync() {
    // Periodically re-synchronize to maintain accuracy
    DispatchQueue.global().async { [weak self] in
      while self?.pingLoop == false {
        let currentTime = mach_absolute_time()
        if currentTime - (self?.lastSyncTime ?? 0) >= self?.syncInterval ?? 1_000_000_000 {
          self?.lastSyncTime = currentTime
          self?.sendTimePing()
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
  }

  private func handleStartRecording(_ json: [String: Any]) {
    guard let startAt = json["startAt"] as? Double else { return }
    
    cameraManager.prepareCamera { [weak self] success in
      guard let self = self, success else { return }
      
      let now = Date().timeIntervalSince1970
      let delay = startAt - now
      
      if delay < 0 {
        print("Missed scheduled time!")
        return
      }
      
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if let path = self.cameraManager.startRecording()?.path {
          self.recordingCompletion?(path)
        }
      }
    }
  }

  private func startPingPong() {
    pingLoop = true
    pingCount = 0
    offsets.removeAll()
    calculatedOffset = nil
    sendTimePing()
  }
}

extension PeerManager: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, FlutterStreamHandler {
  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    switch state {
      case .connected:
        print("Connected to \(peerID.displayName)")
        connectedPeer = peerID
        startPingPong()
        eventSink?(["connectionState": "connected"])
      case .notConnected:
        print("Disconnected from \(peerID.displayName)")
        if connectedPeer == peerID {
          connectedPeer = nil
          calculatedOffset = nil
        }
        eventSink?(["connectionState": "disconnected"])
      case .connecting:
        print("Connecting to \(peerID.displayName)...")
        eventSink?(["connectionState": "connecting"])
      @unknown default:
        break
    }
  }
  
  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    do {
      guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let type = json["type"] as? String else {
        print("Invalid data received")
        return
      }
      
      switch type {
      case "timePing":
        handleTimePing(json)
      case "timePong":
        handleTimePong(json)
      case "startRecording":
        handleStartRecording(json)
      case "stopRecording":
        cameraManager.stopRecording()
      default:
        print("Unknown message type: \(type)")
      }
    } catch {
      print("Failed to decode received data: \(error)")
    }
  }
  
  func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
  func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
  func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
  
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    invitationHandler(true, session)
  }
  
  func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
    if !discoveredPeers.contains(peerID) {
      discoveredPeers.append(peerID)
    }
  }
  
  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    if let index = discoveredPeers.firstIndex(of: peerID) {
      discoveredPeers.remove(at: index)
    }
  }
  
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    print("Failed to start advertising: \(error.localizedDescription)")
  }
  
  func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    print("Failed to start browsing: \(error.localizedDescription)")
  }
  
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }
  
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}