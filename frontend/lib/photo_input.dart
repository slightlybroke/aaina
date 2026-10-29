import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

class PhotoInputException implements Exception {
  final String message;
  const PhotoInputException(this.message);
}

String photoInputMessage(Object error) {
  if (error is PhotoInputException) return error.message;
  if (error is PlatformException) {
    return switch (error.code) {
      'photo_access_denied' || 'photo_access_restricted' => 'Photo access was denied. Allow access in Settings, then choose the photo again, or use Take photo.',
      'already_active' => 'The photo picker is already open. Finish or cancel that selection first.',
      'camera_access_denied' ||
      'CameraAccessDenied' ||
      'CameraAccessDeniedWithoutPrompt' => 'Camera access was denied. Allow camera access in Settings, or use Choose photo.',
      _ => 'The photo picker could not open or read this selection. Try again, or switch input methods.',
    };
  }
  return 'The selected photo could not be read. Download the original to this device and choose it again, or use Take photo.';
}

/// XFile reads work for Android content-provider copies and web blobs; never use File(path).
class PhotoInput {
  final ImagePicker picker;
  final Future<Uint8List> Function(Uint8List) prepare;
  PhotoInput({
    ImagePicker? picker,
    Future<Uint8List> Function(Uint8List)? prepare,
  }) : picker = picker ?? ImagePicker(),
       prepare = prepare ?? preparePhoto;

  Future<Uint8List?> gallery() async {
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2560,
      maxHeight: 2560,
      requestFullMetadata: false,
    );
    return file == null ? null : read(file);
  }

  Future<Uint8List> read(XFile file) async {
    if (await file.length() > 30_000_000) {
      throw const PhotoInputException('Choose an original photo under 30 MB.');
    }
    return prepare(await file.readAsBytes());
  }

  Future<Uint8List?> recover() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final response = await picker.retrieveLostData();
    if (response.exception != null) throw response.exception!;
    final files = response.files;
    return files == null || files.isEmpty ? null : read(files.first);
  }
}

/// Decode locally, validate the real pixel dimensions, and normalize to server-supported JPEG.
/// Never upscale or upload here. Unsupported device codecs fail with an actionable message.
Future<Uint8List> preparePhoto(
  Uint8List bytes, {
  int minimumSide = 1080,
  int maximumWidth = 2560,
  int maximumHeight = 2560,
}) async {
  if (bytes.isEmpty || bytes.length > 30_000_000) {
    throw const PhotoInputException(
      'Choose a readable original photo under 30 MB.',
    );
  }
  if (kIsWeb) {
    return prepareBrowserPhoto(
      bytes,
      minimumSide: minimumSide,
      maximumWidth: maximumWidth,
      maximumHeight: maximumHeight,
    );
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w * h > 25_000_000) {
      throw const PhotoInputException(
        'Choose a photo under 25 megapixels, or export a smaller original.',
      );
    }
    final widthScale = maximumWidth / w;
    final heightScale = maximumHeight / h;
    final scale = widthScale < heightScale ? widthScale : heightScale;
    final width = scale < 1 ? (w * scale).round() : w;
    final height = scale < 1 ? (h * scale).round() : h;
    if (width < minimumSide || height < minimumSide) {
      throw PhotoInputException(
        'This photo is $w × $h pixels. ${minimumSide == 1080 ? 'HD analysis' : 'VTO'} needs at least $minimumSide pixels on the short side after resizing. Choose a higher-resolution original; enlarging it will not restore detail.',
      );
    }
    codec = await descriptor.instantiateCodec(
      targetWidth: width,
      targetHeight: height,
    );
    decoded = (await codec.getNextFrame()).image;
    final rgba = await decoded.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) {
      throw const PhotoInputException(
        'This image could not be decoded. Export it as JPEG or PNG and try again.',
      );
    }
    final jpeg = await compute(_encodeJpeg, (
      width: decoded.width,
      height: decoded.height,
      pixels: rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
    ));
    if (jpeg.length >= 10_000_000) {
      throw PhotoInputException(
        'The prepared photo exceeds 10 MB. Export a smaller JPEG without reducing the short side below $minimumSide pixels.',
      );
    }
    return jpeg;
  } on PhotoInputException {
    rethrow;
  } catch (_) {
    throw const PhotoInputException(
      'This device cannot decode that image, or the file is damaged. Export the original as JPEG or PNG and choose it again.',
    );
  } finally {
    decoded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Flutter web cannot expose encoded ImageDescriptor dimensions. Check a bounded header
/// before decoding a single frame, then bake orientation and strip metadata by copying pixels.
Uint8List prepareBrowserPhoto(
  Uint8List bytes, {
  int minimumSide = 1080,
  int maximumWidth = 2560,
  int maximumHeight = 2560,
}) {
  try {
    if (bytes.isEmpty || bytes.length > 30000000) {
      throw const PhotoInputException(
        'Choose a readable original photo under 30 MB.',
      );
    }
    final decoder = img.findDecoderForData(bytes);
    if (decoder is! img.JpegDecoder &&
        decoder is! img.PngDecoder &&
        decoder is! img.WebPDecoder) {
      throw const PhotoInputException(
        'This browser supports JPEG, PNG and WebP here. Export the original in one of those formats and retry.',
      );
    }
    final header = decoder!.startDecode(bytes);
    if (header == null) {
      throw const PhotoInputException(
        'The selected image header could not be decoded.',
      );
    }
    if (header.width * header.height > 25000000) {
      throw const PhotoInputException(
        'Choose a photo under 25 megapixels, or export a smaller original.',
      );
    }
    final frame = decoder.decodeFrame(0);
    if (frame == null) {
      throw const PhotoInputException(
        'This image could not be decoded. Export it as JPEG or PNG and try again.',
      );
    }
    final oriented = img.bakeOrientation(frame);
    final w = oriented.width, h = oriented.height;
    final scale = (maximumWidth / w) < (maximumHeight / h)
        ? maximumWidth / w
        : maximumHeight / h;
    final width = scale < 1 ? (w * scale).round() : w,
        height = scale < 1 ? (h * scale).round() : h;
    if (width < minimumSide || height < minimumSide) {
      throw PhotoInputException(
        'This photo is $w × $h pixels. ${minimumSide == 1080 ? 'HD analysis' : 'VTO'} needs at least $minimumSide pixels on the short side after resizing. Choose a higher-resolution original; enlarging it will not restore detail.',
      );
    }
    final resized = width == w && height == h
        ? oriented
        : img.copyResize(oriented, width: width, height: height);
    final output = _encodeJpeg((
      width: width,
      height: height,
      pixels: resized.getBytes(order: img.ChannelOrder.rgba),
    ));
    if (output.length >= 10000000) {
      throw const PhotoInputException(
        'The prepared photo exceeds 10 MB. Export a smaller JPEG and retry.',
      );
    }
    return output;
  } on PhotoInputException {
    rethrow;
  } catch (_) {
    throw const PhotoInputException(
      'The selected image could not be prepared safely. Export the original as JPEG or PNG and retry.',
    );
  }
}

Uint8List _encodeJpeg(({int width, int height, Uint8List pixels}) input) {
  final image = img.Image.fromBytes(
    width: input.width,
    height: input.height,
    bytes: input.pixels.buffer,
    bytesOffset: input.pixels.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}
