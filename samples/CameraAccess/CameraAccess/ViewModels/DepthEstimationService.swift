//
//  DepthEstimationService.swift
//  CameraAccess
//

import CoreML
import CoreVideo
import UIKit

struct EstimatedSize {
  let widthCm: Double
  let heightCm: Double
  let depthMeters: Double
}

enum DepthEstimationError: Error {
  case imageConversionFailed
  case missingOutput
  case modelNotBundled
}

/// Runs Apple's DepthPro model (metric monocular depth estimation) to
/// produce a rough real-world size estimate for a region of an image.
/// Intended as an on-demand fallback when nothing else (barcode,
/// classification) could identify the object — accuracy is secondary to
/// having *some* estimate, so this leans on a couple of simplifying
/// assumptions (see `assumedHorizontalFOVDegrees`) rather than precise optics.
final class DepthEstimationService {
  private static let modelInputSize = 1536
  /// The Meta glasses camera's exact field of view isn't published by the
  /// DAT SDK, so this is an approximation for a wide-angle, action-cam-style
  /// lens. Size estimates scale directly with this assumption — treat
  /// results as rough, not exact.
  private static let assumedHorizontalFOVDegrees: Double = 80

  private var model: MLModel?

  /// - Parameter boundingBox: normalized (0...1, origin bottom-left, like
  ///   Vision) region of `image` the object occupies. Pass the full image
  ///   (0,0,1,1) when the caller has already cropped to the object (e.g. the
  ///   reticle) rather than locating it within a larger frame.
  func estimateSize(in image: UIImage, boundingBox: CGRect) async throws -> EstimatedSize {
    let model = try loadModelIfNeeded()

    guard let pixelBuffer = Self.makePixelBuffer(from: image, size: Self.modelInputSize) else {
      throw DepthEstimationError.imageConversionFailed
    }

    let originalWidthArray = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .double)
    originalWidthArray[0] = NSNumber(value: Double(image.size.width))

    let input = try MLDictionaryFeatureProvider(dictionary: [
      "image": MLFeatureValue(pixelBuffer: pixelBuffer),
      "originalWidth": MLFeatureValue(multiArray: originalWidthArray),
    ])

    let output = try await Task.detached(priority: .userInitiated) {
      try model.prediction(from: input)
    }.value

    guard let depthMap = output.featureValue(for: "depthMeters")?.multiArrayValue else {
      throw DepthEstimationError.missingOutput
    }

    let depthMeters = Self.medianDepth(in: depthMap, boundingBox: boundingBox)
    let (widthCm, heightCm) = Self.sizeInCentimeters(
      boundingBox: boundingBox, depthMeters: depthMeters, imageSize: image.size
    )

    return EstimatedSize(widthCm: widthCm, heightCm: heightCm, depthMeters: depthMeters)
  }

  /// Loads the model compiled into the app bundle at build time — the
  /// `.mlpackage` is checked into the repo (see `MLModels/`) and added as a
  /// project resource, so Xcode compiles it to `.mlmodelc` automatically;
  /// no network access or on-device compilation is needed at runtime.
  private func loadModelIfNeeded() throws -> MLModel {
    if let model { return model }
    guard
      let url = Bundle.main.url(forResource: "DepthProPruned10QuantizedLinear", withExtension: "mlmodelc")
    else {
      throw DepthEstimationError.modelNotBundled
    }
    let loaded = try MLModel(contentsOf: url)
    model = loaded
    return loaded
  }

  /// Samples a grid of points within `boundingBox` and returns their median
  /// depth — cheap noise resistance against a handful of outlier pixels
  /// (e.g. reflections, edges) without averaging across the whole region.
  private static func medianDepth(in depthMap: MLMultiArray, boundingBox: CGRect) -> Double {
    let height = depthMap.shape[2].intValue
    let width = depthMap.shape[3].intValue

    let minX = max(0, Int(boundingBox.minX * CGFloat(width)))
    let maxX = min(width - 1, Int(boundingBox.maxX * CGFloat(width)))
    let minY = max(0, Int((1 - boundingBox.maxY) * CGFloat(height)))
    let maxY = min(height - 1, Int((1 - boundingBox.minY) * CGFloat(height)))

    guard maxX > minX, maxY > minY else {
      return depthMap[0].doubleValue
    }

    let stepX = max(1, (maxX - minX) / 20)
    let stepY = max(1, (maxY - minY) / 20)

    var values: [Double] = []
    for y in stride(from: minY, to: maxY, by: stepY) {
      for x in stride(from: minX, to: maxX, by: stepX) {
        values.append(depthMap[y * width + x].doubleValue)
      }
    }

    values.sort()
    return values[values.count / 2]
  }

  /// Pinhole-camera approximation: at a given depth, the real-world span of
  /// the full frame is `2 * depth * tan(FOV/2)` — scaling that by the
  /// bounding box's fraction of the frame gives the object's approximate size.
  private static func sizeInCentimeters(
    boundingBox: CGRect, depthMeters: Double, imageSize: CGSize
  ) -> (width: Double, height: Double) {
    let horizontalFOVRadians = assumedHorizontalFOVDegrees * .pi / 180
    let fullWidthMeters = 2 * depthMeters * tan(horizontalFOVRadians / 2)

    let verticalFOVRadians = 2 * atan(tan(horizontalFOVRadians / 2) * (imageSize.height / imageSize.width))
    let fullHeightMeters = 2 * depthMeters * tan(verticalFOVRadians / 2)

    let widthCm = boundingBox.width * fullWidthMeters * 100
    let heightCm = boundingBox.height * fullHeightMeters * 100
    return (widthCm, heightCm)
  }

  private static func makePixelBuffer(from image: UIImage, size: Int) -> CVPixelBuffer? {
    guard let cgImage = image.cgImage else { return nil }

    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, size, size, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
      )
    else {
      return nil
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    return buffer
  }
}
