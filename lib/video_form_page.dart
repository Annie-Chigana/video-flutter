import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

/// Web (Chrome): the browser runs on your PC, so localhost works.
/// Android emulator: the host PC is 10.0.2.2.
/// Physical phone: use your PC's LAN IP (e.g. http://192.168.1.20:3001),
/// or run `adb reverse tcp:3001 tcp:3001` and use http://localhost:3001.
const String apiHost =
    String.fromEnvironment('API_HOST', defaultValue: '10.0.2.2:3001');

final String baseUrl = kIsWeb ? 'http://localhost:3001' : 'http://$apiHost';
// Must match the limits/extensions on the server.
const int maxUploadBytes = 25 * 1024 * 1024;
const List<String> imageExtensions = ['jpg', 'jpeg', 'png', 'webp'];
const List<String> audioExtensions = ['mp3', 'wav', 'm4a', 'aac', 'ogg'];
const int maxImages = 8;

class ColorOption {
  final String name;
  final String hex; // sent to the server / Remotion
  final Color color;

  const ColorOption(this.name, this.hex, this.color);
}

const List<ColorOption> colorOptions = [
  ColorOption('Red', '#E53935', Color(0xFFE53935)),
  ColorOption('Orange', '#FB8C00', Color(0xFFFB8C00)),
  ColorOption('Yellow', '#FDD835', Color(0xFFFDD835)),
  ColorOption('Green', '#43A047', Color(0xFF43A047)),
  ColorOption('Blue', '#1E88E5', Color(0xFF1E88E5)),
  ColorOption('Purple', '#8E24AA', Color(0xFF8E24AA)),
  ColorOption('Pink', '#EC407A', Color(0xFFEC407A)),
  ColorOption('Black', '#212121', Color(0xFF212121)),
];

class VideoFormPage extends StatefulWidget {
  const VideoFormPage({super.key});

  @override
  State<VideoFormPage> createState() => _VideoFormPageState();
}

class _VideoFormPageState extends State<VideoFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hobbyController = TextEditingController();
  final _sportController = TextEditingController();
  final _playerController = TextEditingController();
  final _fandomController = TextEditingController();
  final _ageController = TextEditingController();

  ColorOption? _selectedColor;
  String? _colorError;

  PlatformFile? _imageFile;
  String? _imageError;

  PlatformFile? _songFile;
  String? _songError;

  VideoPlayerController? _videoController;

  bool _isGenerating = false;
  bool _isMuted = false;
  String? _videoUrl;
  String? _errorMessage;

  List<PlatformFile> _imageFiles = [];
  //String? _imageError;

  @override
  void dispose() {
    _nameController.dispose();
    _hobbyController.dispose();
    _ageController.dispose();
    _videoController?.dispose();
    _sportController.dispose();
    _playerController.dispose();
    _fandomController.dispose();
    super.dispose();
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  // -------------------------------------------------------------------------
  // File picking
  // -------------------------------------------------------------------------
  Future<PlatformFile?> _pickFile(List<String> extensions) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: true, // we need the bytes (the only option on web)
    );

    if (result == null || result.files.isEmpty) return null;
    return result.files.first;
  }

Future<void> _pickImages() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: imageExtensions,
    allowMultiple: true,
    withData: true,
  );
  if (result == null || result.files.isEmpty || !mounted) return;

  final added = <PlatformFile>[];
  String? error;

  for (final file in result.files) {
    if (_imageFiles.length + added.length >= maxImages) {
      error = 'You can add up to $maxImages images.';
      break;
    }
    if (file.bytes == null) {
      error = 'Could not read ${file.name}.';
      continue;
    }
    if (file.size > maxUploadBytes) {
      error = '${file.name} is too large (max 25 MB).';
      continue;
    }
    added.add(file);
  }

  setState(() {
    _imageFiles = [..._imageFiles, ...added];
    _imageError = error;
  });
}

void _removeImage(int index) {
  setState(() {
    _imageFiles = [..._imageFiles]..removeAt(index);
  });
}

  Future<void> _pickSong() async {
    final file = await _pickFile(audioExtensions);
    if (file == null || !mounted) return;

    setState(() {
      if (file.bytes == null) {
        _songError = 'Could not read that song. Try another one.';
      } else if (file.size > maxUploadBytes) {
        _songError = 'Song is too large (max 25 MB).';
      } else {
        _songFile = file;
        _songError = null;
      }
    });
  }

  // -------------------------------------------------------------------------
  // Submit + generate
  // -------------------------------------------------------------------------
  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final formValid = _formKey.currentState!.validate();

    // These aren't FormFields, so validate them manually.
    setState(() {
      _colorError =
          _selectedColor == null ? 'Please pick a favorite color' : null;
      _imageError = _imageFiles.isEmpty
    ? (_imageError ?? 'Please upload at least one image')
    : null;
      _songError =
          _songFile == null ? (_songError ?? 'Please upload a song') : null;
    });

    if (!formValid ||
        _selectedColor == null ||
        _imageFiles.isEmpty ||
        _songFile == null) {
      return;
    }

    await _generateVideo();
  }

  Future<void> _generateVideo() async {
    // Detach the old controller from the UI first, then dispose it,
    // so the widget tree never builds a disposed controller.
    final old = _videoController;
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
      _videoUrl = null;
      _videoController = null;
      _isMuted = false;
    });
    await old?.dispose();

    VideoPlayerController? controller;

    try {
      final song = _songFile!;

final request = http.MultipartRequest(
  'POST',
  Uri.parse('$baseUrl/api/videos'),
)
  ..fields['name'] = _nameController.text.trim()
  ..fields['age'] = _ageController.text.trim()
  ..fields['hobby'] = _hobbyController.text.trim()
  ..fields['favoriteColor'] = _selectedColor!.hex
  ..fields['favoriteColorName'] = _selectedColor!.name
  ..fields['favoriteSport'] = _sportController.text.trim()
  ..fields['favoritePlayer'] = _playerController.text.trim()
  ..fields['fandom'] = _fandomController.text.trim();


for (final image in _imageFiles) {
  request.files.add(
    http.MultipartFile.fromBytes('images', image.bytes!, filename: image.name),
  );
}
request.files.add(
  http.MultipartFile.fromBytes('song', song.bytes!, filename: song.name),
);
      // The server replies after rendering, so allow plenty of time.
      final streamed = await request.send().timeout(const Duration(minutes: 5));
      final response = await http.Response.fromStream(streamed);

      debugPrint('STATUS: ${response.statusCode}');
      debugPrint('RESPONSE: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
          'Server returned ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body);
      final videoPath = data['videoUrl']?.toString();

      if (videoPath == null || videoPath.isEmpty) {
        throw Exception('Server did not return a video URL.');
      }

      // Server returns a relative path like /videos/video-123.mp4
      final playableVideoUrl =
          videoPath.startsWith('http') ? videoPath : '$baseUrl$videoPath';

      debugPrint('Playable video URL: $playableVideoUrl');

      controller = VideoPlayerController.networkUrl(
        Uri.parse(playableVideoUrl),
      );

      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(1);

      var muted = false;
      var playFailed = false;

      try {
        await controller.play();
      } catch (e) {
        debugPrint('Play with sound failed: $e');
        playFailed = true;
      }

      if (kIsWeb) {
        // Browsers can block autoplay with sound (the render took a while,
        // so the button click is no longer a "fresh" user gesture).
        // Check that playback actually started; if not, start it muted.
        await Future.delayed(const Duration(milliseconds: 600));
        final notMoving = controller.value.position == Duration.zero;

        if (playFailed || notMoving) {
          await controller.setVolume(0);
          await controller.play();
          muted = true;
        }
      }

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _videoUrl = playableVideoUrl;
        _videoController = controller;
        _isMuted = muted;
        _isGenerating = false;
      });
    } catch (e) {
      debugPrint('Video generation error: $e');

      // Don't leak the controller if initialize()/play() failed.
      await controller?.dispose();

      if (!mounted) return;

      setState(() {
        _isGenerating = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _toggleMute() async {
    final controller = _videoController;
    if (controller == null) return;

    final mute = !_isMuted;
    await controller.setVolume(mute ? 0 : 1);

    // Tapping unmute is a real user gesture, so make sure it's playing.
    if (!mute && !controller.value.isPlaying) {
      await controller.play();
    }

    if (!mounted) return;
    setState(() => _isMuted = mute);
  }

  // -------------------------------------------------------------------------
  // UI pieces
  // -------------------------------------------------------------------------
  Widget _buildColorPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Favorite color',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: colorOptions.map((option) {
            final selected = _selectedColor == option;
            return Tooltip(
              message: option.name,
              child: GestureDetector(
                onTap: _isGenerating
                    ? null
                    : () => setState(() {
                          _selectedColor = option;
                          _colorError = null;
                        }),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: option.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? Colors.black : Colors.grey.shade300,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: selected
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                ),
              ),
            );
          }).toList(),
        ),
        _fieldError(_colorError),
      ],
    );
  }

  Widget _fieldError(String? message) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        message,
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildImagePicker() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Your pictures (${_imageFiles.length}/$maxImages)',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: (_isGenerating || _imageFiles.length >= maxImages)
            ? null
            : _pickImages,
        icon: const Icon(Icons.add_photo_alternate),
        label: Text(_imageFiles.isEmpty ? 'Choose images' : 'Add more images'),
      ),
      if (_imageFiles.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < _imageFiles.length; i++)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      _imageFiles[i].bytes!,
                      width: 90,
                      height: 90,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: -8,
                    right: -8,
                    child: GestureDetector(
                      onTap: _isGenerating ? null : () => _removeImage(i),
                      child: const CircleAvatar(
                        radius: 12,
                        backgroundColor: Colors.black87,
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
      _fieldError(_imageError),
    ],
  );
}

  Widget _buildSongPicker() {
    final song = _songFile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your song',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _isGenerating ? null : _pickSong,
          icon: const Icon(Icons.music_note),
          label: Text(song == null ? 'Choose song' : 'Change song'),
        ),
        if (song != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.audiotrack, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${song.name}\n${_formatSize(song.size)}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        _fieldError(_songError),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Your Video'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Tell us about you',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Fill in the form and we will generate a personalised video.',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),

                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        enabled: !_isGenerating,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter your name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _ageController,
                        enabled: !_isGenerating,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(3),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Age',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final age = int.tryParse(value?.trim() ?? '');
                          if (age == null) return 'Please enter your age';
                          if (age < 1 || age > 120) {
                            return 'Enter an age between 1 and 120';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _hobbyController,
                        enabled: !_isGenerating,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Hobby',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a hobby';
                          }
                          return null;
                        },

                        
                      ),

                      TextFormField(
  controller: _sportController,
  enabled: !_isGenerating,
  textInputAction: TextInputAction.next,
  textCapitalization: TextCapitalization.words,
  decoration: const InputDecoration(
    labelText: 'Favorite sport',
    border: OutlineInputBorder(),
  ),
  validator: (value) => (value == null || value.trim().isEmpty)
      ? 'Please enter your favorite sport'
      : null,
),
const SizedBox(height: 16),

TextFormField(
  controller: _playerController,
  enabled: !_isGenerating,
  textInputAction: TextInputAction.next,
  textCapitalization: TextCapitalization.words,
  decoration: const InputDecoration(
    labelText: 'Favorite player',
    border: OutlineInputBorder(),
  ),
  validator: (value) => (value == null || value.trim().isEmpty)
      ? 'Please enter your favorite player'
      : null,
),
const SizedBox(height: 16),

TextFormField(
  controller: _fandomController,
  enabled: !_isGenerating,
  textInputAction: TextInputAction.done,
  textCapitalization: TextCapitalization.words,
  decoration: const InputDecoration(
    labelText: 'Fandom',
    hintText: 'e.g. your team or fan group',
    border: OutlineInputBorder(),
  ),
  validator: (value) => (value == null || value.trim().isEmpty)
      ? 'Please enter your fandom'
      : null,
),
const SizedBox(height: 20),
                      const SizedBox(height: 20),

                      _buildColorPicker(),
                      const SizedBox(height: 24),

                      _buildImagePicker(),
                      const SizedBox(height: 24),

                      _buildSongPicker(),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                ElevatedButton(
                  onPressed: _isGenerating ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    _isGenerating ? 'Generating...' : 'Generate Video',
                  ),
                ),

                const SizedBox(height: 30),

                if (_isGenerating)
                  const Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text(
                        'Uploading and generating your video...\n'
                        'This may take a little while.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),

                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: Colors.red.shade900),
                    ),
                  ),

                if (controller != null && controller.value.isInitialized)
                  Column(
                    children: [
                      const Text(
                        'Your generated video',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 640),
                            child: VideoPlayer(controller),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 40,
                            onPressed: () {
                              setState(() {
                                if (controller.value.isPlaying) {
                                  controller.pause();
                                } else {
                                  controller.play();
                                }
                              });
                            },
                            icon: Icon(
                              controller.value.isPlaying
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                            ),
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            iconSize: 40,
                            tooltip: _isMuted ? 'Unmute' : 'Mute',
                            onPressed: _toggleMute,
                            icon: Icon(
                              _isMuted ? Icons.volume_off : Icons.volume_up,
                            ),
                          ),
                        ],
                      ),
                      if (_isMuted)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Tap the speaker to hear your song.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      if (_videoUrl != null) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Video URL:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(_videoUrl!),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
