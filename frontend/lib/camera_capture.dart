import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Boundary for camera hardware. Tests can exercise the screen without accessing a real feed.
abstract class PhotoCamera {
  List<CameraDescription> get cameras;
  Future<void> open(CameraDescription camera);
  Widget preview();
  Future<XFile> capture();
  Future<void> close();
}

class DevicePhotoCamera implements PhotoCamera {
  @override
  final List<CameraDescription> cameras;
  CameraController? _controller;
  DevicePhotoCamera(this.cameras);
  static Future<PhotoCamera> load() async =>
      DevicePhotoCamera(await availableCameras());
  @override
  Future<void> open(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
    );
    _controller = controller;
    await controller.initialize();
  }

  @override
  Widget preview() => CameraPreview(_controller!);
  @override
  Future<XFile> capture() => _controller!.takePicture();
  @override
  Future<void> close() async {
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }
}

String cameraMessage(Object error) {
  if (error is CameraException) {
    return switch (error.code) {
      'CameraAccessDenied' ||
      'CameraAccessDeniedWithoutPrompt' ||
      'CameraAccessRestricted' => 'Camera access is unavailable. Allow camera access in Settings, or go back and use Choose photo.',
      _ => 'The camera could not start or capture a photo. Retry, switch cameras, or go back and use Choose photo.',
    };
  }
  return 'No usable camera is available. Go back and use Choose photo, or retry.';
}

class CameraCapture extends StatefulWidget {
  final Future<PhotoCamera> Function() load;
  const CameraCapture({super.key, this.load = DevicePhotoCamera.load});
  @override
  State<CameraCapture> createState() => _CameraCaptureState();
}

class _CameraCaptureState extends State<CameraCapture>
    with WidgetsBindingObserver {
  PhotoCamera? _camera;
  CameraDescription? _selected;
  bool _opening = true, _ready = false, _capturing = false, _foreground = true;
  String? _error;
  int _generation = 0;
  Future<void> _operation = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final camera = await widget.load();
      if (!mounted) {
        await camera.close();
        return;
      }
      _camera = camera;
      if (camera.cameras.isEmpty) throw StateError('no cameras');
      final selected = camera.cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => camera.cameras.first,
      );
      await _open(selected);
    } catch (e) {
      if (mounted) {
        setState(() {
          _opening = false;
          _error = cameraMessage(e);
        });
      }
    }
  }

  Future<void> _open(CameraDescription description) {
    final generation = ++_generation;
    _selected = description;
    setState(() {
      _opening = true;
      _ready = false;
      _error = null;
    });
    final previous = _operation;
    return _operation = () async {
      await previous;
      try {
        await _camera!.close();
        if (!mounted || !_foreground || generation != _generation) {
          if (mounted && generation == _generation) {
            setState(() => _opening = false);
          }
          return;
        }
        await _camera!.open(description);
        if (!mounted || !_foreground || generation != _generation) {
          await _camera!.close();
          if (mounted && generation == _generation) {
            setState(() => _opening = false);
          }
          return;
        }
        setState(() {
          _ready = true;
          _opening = false;
        });
      } catch (e) {
        await _camera?.close();
        if (mounted && generation == _generation) {
          setState(() {
            _opening = false;
            _error = cameraMessage(e);
          });
        }
      }
    }();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (_selected != null &&
          !_ready &&
          !_opening &&
          _error == null &&
          !_capturing) {
        unawaited(_open(_selected!));
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      if (_ready) {
        ++_generation;
        setState(() => _ready = false);
        _operation = _operation.then((_) => _camera?.close());
      }
    }
  }

  Future<void> _capture() async {
    if (!_ready || _capturing) return;
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      final photo = await _camera!.capture();
      if (mounted) Navigator.of(context).pop(photo);
    } catch (e) {
      if (mounted) setState(() => _error = cameraMessage(e));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    unawaited(_operation.then((_) => _camera?.close()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameras = _camera?.cameras ?? [];
    final hasFront = cameras.any(
      (c) => c.lensDirection == CameraLensDirection.front,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Take photo')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _ready
                    ? _camera!.preview()
                    : _opening
                    ? const CircularProgressIndicator()
                    : const Icon(Icons.no_photography_outlined, size: 64),
              ),
            ),
            if (!hasFront && cameras.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No front camera is available. Using another camera on this device.',
                ),
              ),
            if (_ready)
              Text(
                _selected!.lensDirection == CameraLensDirection.front
                    ? 'Front camera'
                    : 'Rear / external camera',
              ),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _capturing
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  if (_error != null)
                    OutlinedButton(
                      onPressed: _opening || _capturing
                          ? null
                          : () {
                              if (_selected == null) {
                                unawaited(_load());
                              } else {
                                unawaited(_open(_selected!));
                              }
                            },
                      child: const Text('Retry camera'),
                    ),
                  OutlinedButton.icon(
                    onPressed: cameras.length < 2 || _opening || _capturing
                        ? null
                        : () {
                            final direction =
                                _selected!.lensDirection ==
                                    CameraLensDirection.front
                                ? CameraLensDirection.back
                                : CameraLensDirection.front;
                            final next = cameras.firstWhere(
                              (c) => c.lensDirection == direction,
                              orElse: () =>
                                  cameras[(cameras.indexOf(_selected!) + 1) %
                                      cameras.length],
                            );
                            unawaited(_open(next));
                          },
                    icon: const Icon(Icons.cameraswitch_outlined),
                    label: const Text('Switch camera'),
                  ),
                  FilledButton.icon(
                    onPressed: !_ready || _opening || _capturing
                        ? null
                        : _capture,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(_capturing ? 'Capturing…' : 'Use photo'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
