import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VideoUploadManager {
  static const MethodChannel _channel = MethodChannel('com.glitch.athlon_test');
  static const EventChannel _uploadEventChannel = EventChannel('com.glitch.athlon_test/upload_events');
  
  Stream<Map<String, dynamic>>? _uploadEventStream;
  
  // Singleton pattern
  static final VideoUploadManager _instance = VideoUploadManager._internal();
  factory VideoUploadManager() => _instance;
  VideoUploadManager._internal() {
    _initializeUploadEvents();
  }
  
  void _initializeUploadEvents() {
    _uploadEventStream = _uploadEventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => Map<String, dynamic>.from(event));
  }
  
  // Upload a video file
  Future<String?> uploadVideo({
    required String filePath,
    required String bucketId,
    required String applicationKeyId,
    required String applicationKey,
  }) async {
    try {
      final String? fileId = await _channel.invokeMethod('uploadVideo', {
        'filePath': filePath,
        'bucketId': bucketId,
        'applicationKeyId': applicationKeyId,
        'applicationKey': applicationKey,
      });
      return fileId;
    } on PlatformException catch (e) {
      print('Error uploading video: ${e.message}');
      return null;
    }
  }
  
  // Cancel an ongoing upload
  Future<bool> cancelUpload(String filePath) async {
    try {
      final bool success = await _channel.invokeMethod('cancelUpload', {
        'filePath': filePath,
      });
      return success;
    } on PlatformException catch (e) {
      print('Error canceling upload: ${e.message}');
      return false;
    }
  }
  
  // Listen to upload progress
  Stream<Map<String, dynamic>> get uploadEvents {
    _uploadEventStream ??= _uploadEventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => Map<String, dynamic>.from(event));
    return _uploadEventStream!;
  }
}

// Example usage in a Flutter widget:
class UploadScreen extends StatefulWidget {
  final String videoPath;
  
  const UploadScreen({super.key, required this.videoPath});
  
  @override
  UploadScreenState createState() => UploadScreenState();
}

class UploadScreenState extends State<UploadScreen> {
  final _uploadManager = VideoUploadManager();
  double _uploadProgress = 0.0;
  String? _fileId;
  String? _error;
  
  @override
  void initState() {
    super.initState();
    _startUpload();
    _listenToProgress();
  }
  
  void _listenToProgress() {
    _uploadManager.uploadEvents.listen((event) {
      if (event['type'] == 'uploadProgress' && 
          event['filePath'] == widget.videoPath) {
        setState(() {
          _uploadProgress = event['progress'] as double;
        });
      }
    });
  }
  
  Future<void> _startUpload() async {
    try {
      final fileId = await _uploadManager.uploadVideo(
        filePath: widget.videoPath,
        bucketId: 'YOUR_BUCKET_ID',
        applicationKeyId: 'YOUR_APPLICATION_KEY_ID',
        applicationKey: 'YOUR_APPLICATION_KEY',
      );
      
      setState(() {
        _fileId = fileId;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Uploading Video')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_error != null)
            Text('Error: $_error', style: TextStyle(color: Colors.red)),
          if (_fileId != null)
            Text('Upload complete! File ID: $_fileId'),
          LinearProgressIndicator(value: _uploadProgress),
          Text('${(_uploadProgress * 100).toStringAsFixed(1)}%'),
          if (_uploadProgress < 1.0)
            ElevatedButton(
              onPressed: () => _uploadManager.cancelUpload(widget.videoPath),
              child: Text('Cancel Upload'),
            ),
        ],
      ),
    );
  }
}