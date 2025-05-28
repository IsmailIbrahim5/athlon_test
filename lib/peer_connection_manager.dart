import 'package:athlon_test/video_upload_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PeerConnectionManager {
  static const MethodChannel _channel = MethodChannel('com.glitch.athlon_test');
  static const EventChannel _eventChannel = EventChannel('com.glitch.athlon_test/events');
  
  Stream<Map<String, dynamic>>? _eventStream;
  bool _isSubFrameAccurate = false;
  
  // Singleton pattern
  static final PeerConnectionManager _instance = PeerConnectionManager._internal();
  factory PeerConnectionManager() => _instance;
  PeerConnectionManager._internal();
  
  // Initialize event stream
  void initialize() {
    _eventStream = _eventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => Map<String, dynamic>.from(event));
        
    // Listen to events
    _eventStream?.listen((event) {
      if (event.containsKey('isSubFrame')) {
        _isSubFrameAccurate = event['isSubFrame'] as bool;
        print('Sub-frame accuracy: $_isSubFrameAccurate');
      }
      if (event.containsKey('precision')) {
        print('Current precision: ${event['precision']} seconds');
      }
      if (event.containsKey('connectionState')) {
        print('Connection state: ${event['connectionState']}');
      }
    });
  }
  
  // Search for available peers
  Future<List<String>> searchPeers() async {
    try {
      final List<dynamic> peers = await _channel.invokeMethod('searchPeers');
      return peers.cast<String>();
    } on PlatformException catch (e) {
      print('Error searching peers: ${e.message}');
      return [];
    }
  }
  
  // Connect to a specific peer
  Future<bool> connectToPeer(String peerId) async {
    try {
      final bool success = await _channel.invokeMethod('connectPeer', {
        'peerId': peerId,
      });
      return success;
    } on PlatformException catch (e) {
      print('Error connecting to peer: ${e.message}');
      return false;
    }
  }
  
  // Schedule recording with delay
  Future<String> scheduleRecording(double delaySeconds) async {
    if (!_isSubFrameAccurate) {
      print('Warning: Not sub-frame accurate yet. Waiting for better synchronization...');
      return '';
    }
    
    try {
      final String filePath = await _channel.invokeMethod('scheduleRecord', {
        'delay': delaySeconds,
      });
      return filePath;
    } on PlatformException catch (e) {
      print('Error scheduling recording: ${e.message}');
      return '';
    }
  }
  
  // Get current synchronization status
  bool get isSubFrameAccurate => _isSubFrameAccurate;
}

// Example usage in a Flutter widget:
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  RecordingScreenState createState() => RecordingScreenState();
}

class RecordingScreenState extends State<RecordingScreen> {
  final _peerManager = PeerConnectionManager();
  List<String> _availablePeers = [];
  String? _connectedPeerId;
  String? _recordingPath;
  bool _isSubFrameAccurate = false;
  
  @override
  void initState() {
    super.initState();
    _initializePeerManager();
  }
  
  void _initializePeerManager() {
    _peerManager.initialize();
    
    // Listen to events
    _peerManager._eventStream?.listen((event) {
      setState(() {
        if (event.containsKey('isSubFrame')) {
          _isSubFrameAccurate = event['isSubFrame'] as bool;
        }
      });
    });
  }
  
  Future<void> _searchPeers() async {
    final peers = await _peerManager.searchPeers();
    setState(() {
      _availablePeers = peers;
    });
  }
  
  Future<void> _connectToPeer(String peerId) async {
    final success = await _peerManager.connectToPeer(peerId);
    if (success) {
      setState(() {
        _connectedPeerId = peerId;
      });
    }
  }
  
  Future<void> _startRecording() async {
    if (_connectedPeerId != null && _isSubFrameAccurate) {
      final filePath = await _peerManager.scheduleRecording(60.0); // 60 second delay
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => UploadScreen(videoPath: filePath),
        ),
      );
      setState(() {
        _recordingPath = filePath;
      });
    } else if (!_isSubFrameAccurate) {
      // Show warning to user
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Waiting for sub-frame synchronization...')),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Recording')),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: _searchPeers,
            child: Text('Search Peers'),
          ),
          if (_availablePeers.isNotEmpty)
            ..._availablePeers.map((peer) => ListTile(
              title: Text(peer),
              onTap: () => _connectToPeer(peer),
            )),
          if (_connectedPeerId != null)
            Column(
              children: [
                Text('Synchronization Status: ${_isSubFrameAccurate ? "Sub-frame Accurate" : "Calibrating..."}'),
                ElevatedButton(
                  onPressed: _isSubFrameAccurate ? _startRecording : null,
                  child: Text('Start Recording'),
                ),
              ],
            ),
          if (_recordingPath != null)
            Text('Recording saved to: $_recordingPath'),
        ],
      ),
    );
  }
}