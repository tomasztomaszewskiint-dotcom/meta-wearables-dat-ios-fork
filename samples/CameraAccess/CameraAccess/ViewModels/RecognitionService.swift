//
//  RecognitionService.swift
//  CameraAccess
//
//  Created by Tomasz Tomaszewski on 23/07/2026.
//

import CoreImage
import UIKit
import Vision

/// A piece of text detected in an image, with its location in normalized
/// Vision coordinates (origin bottom-left, 0...1 on both axes).
struct RecognizedText: Identifiable {
  let id = UUID()
  let text: String
  let boundingBox: CGRect
}

/// A candidate text-shaped region found by the cheap detection pass, with
/// Vision's confidence score so low-confidence outliers can be filtered out.
struct TextRegionCandidate {
  let boundingBox: CGRect
  let confidence: Float
}

/// A barcode/QR code decoded from an image.
struct DetectedBarcode: Identifiable {
  let id = UUID()
  let payload: String
  let symbology: VNBarcodeSymbology
  let boundingBox: CGRect
}

/// A general-purpose classification of what's in an image (e.g. "bottle",
/// "cheese", "telephone"), from Apple's built-in Vision classifier.
struct ObjectClassification {
  let identifier: String
  let confidence: Float
}

/// The outline of a foreground object's precise boundary (not just a
/// bounding box), as a path in normalized Vision coordinates (unit square,
/// origin bottom-left).
struct ObjectOutline {
  let path: CGPath
}

/// Cheap geometric description of a contour's shape, independent of scale —
/// used to sanity-check/re-rank classification candidates (e.g. a very round
/// contour is more likely a bottle/can/jar than whatever scored highest).
struct ObjectShapeFeatures {
  /// Width / height of the outline's bounding box.
  let aspectRatio: CGFloat
  /// 4π·Area/Perimeter², in 0...1 — 1 is a perfect circle, close to 0 is a
  /// thin/irregular sliver.
  let circularity: CGFloat
}

/// The result of segmenting the main foreground object out of a frame:
/// its outline (for drawing), where it sits in the source image (for
/// spatially cross-referencing against barcodes/text found elsewhere), a
/// background-removed image of just the object for further analysis
/// (classification, fallback OCR) that isn't skewed by whatever's behind it,
/// plus a couple of cheap extra signals (shape, color) about the object itself.
struct ObjectFoundation {
  let outline: ObjectOutline
  /// Normalized (0...1, origin bottom-left), in the same coordinate space
  /// as the image `detectObjectFoundation` was run on — comparable directly
  /// against `DetectedBarcode.boundingBox`/`RecognizedText.boundingBox` from
  /// a call on that same image.
  let boundingBox: CGRect
  let isolatedObjectBuffer: CVPixelBuffer
  let shapeFeatures: ObjectShapeFeatures
  /// Average color over the isolated object crop — an approximation, since
  /// background pixels outside the mask (transparent black) still factor
  /// into the average, pulling it slightly darker than the object alone.
  let dominantColor: UIColor?
}

extension VNBarcodeSymbology {
  /// Symbologies typically used for retail products — QR/Aztec/PDF417 etc.
  /// usually encode arbitrary data (URLs, tickets), not product IDs, so
  /// looking them up against a product database wouldn't make sense.
  static let productSymbologies: Set<VNBarcodeSymbology> = [
    .ean13, .ean8, .upce, .code128, .code39, .code93, .itf14,
  ]
}

/// Runs on-device text recognition (OCR) over camera frames using Vision.
final class RecognitionService {
  func recognizeText(in image: UIImage) async throws -> [RecognizedText] {
    guard let cgImage = image.cgImage else { return [] }

    let handler = VNImageRequestHandler(
      cgImage: cgImage,
      orientation: image.imageOrientation.cgImagePropertyOrientation
    )
    return try await recognizeText(using: handler)
  }

  /// Fallback OCR scoped to a single already-isolated object (see
  /// `detectObjectFoundation`) — used when the object has no barcode of its
  /// own, so text printed on its packaging is the next-best identifying signal.
  func recognizeText(inPixelBuffer pixelBuffer: CVPixelBuffer) async throws -> [RecognizedText] {
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
    return try await recognizeText(using: handler)
  }

  private func recognizeText(using handler: VNImageRequestHandler) async throws -> [RecognizedText] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try handler.perform([request])

    guard let observations = request.results else { return [] }
    return observations.compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      return RecognizedText(text: candidate.string, boundingBox: observation.boundingBox)
    }
  }

  /// Cheaply locates regions that look like text, without reading them —
  /// much lighter than `recognizeText`, intended to run on a full (ideally
  /// downscaled) frame to figure out *where* to point the OCR reticle.
  func detectTextRegions(in image: UIImage) async throws -> [TextRegionCandidate] {
    guard let cgImage = image.cgImage else { return [] }

    let request = VNDetectTextRectanglesRequest()
    request.reportCharacterBoxes = false

    let handler = VNImageRequestHandler(
      cgImage: cgImage,
      orientation: image.imageOrientation.cgImagePropertyOrientation
    )
    try handler.perform([request])

    return (request.results ?? []).map {
      TextRegionCandidate(boundingBox: $0.boundingBox, confidence: $0.confidence)
    }
  }

  /// Detects and decodes barcodes (QR, EAN, UPC, Code128, PDF417, etc.) in an image.
  func detectBarcodes(in image: UIImage) async throws -> [DetectedBarcode] {
    guard let cgImage = image.cgImage else { return [] }

    let request = VNDetectBarcodesRequest()

    let handler = VNImageRequestHandler(
      cgImage: cgImage,
      orientation: image.imageOrientation.cgImagePropertyOrientation
    )
    try handler.perform([request])

    return (request.results ?? []).compactMap { observation in
      guard let payload = observation.payloadStringValue else { return nil }
      return DetectedBarcode(payload: payload, symbology: observation.symbology, boundingBox: observation.boundingBox)
    }
  }

  /// Segments the main foreground object out of `image` — its outline,
  /// where it sits, and a background-removed image of just the object.
  /// Classification and any fallback OCR are deliberately left to the
  /// caller, since whether OCR is worth running depends on whether a
  /// barcode was already found for this object (see `ObjectFoundation`).
  func detectObjectFoundation(in image: UIImage) async throws -> ObjectFoundation? {
    guard let cgImage = image.cgImage else { return nil }
    let orientation = image.imageOrientation.cgImagePropertyOrientation

    let maskRequest = VNGenerateForegroundInstanceMaskRequest()
    let maskHandler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
    try maskHandler.perform([maskRequest])

    guard
      let maskObservation = maskRequest.results?.first,
      !maskObservation.allInstances.isEmpty
    else {
      return nil
    }

    // Full-resolution mask (matching the input image, not Vision's internal
    // analysis resolution) — round objects trace as jagged/blocky on the
    // low-res mask `generateMask` returns, since the curve itself is only as
    // smooth as the mask's own pixel grid.
    let maskPixelBuffer = try maskObservation.generateScaledMaskForImage(
      forInstances: maskObservation.allInstances, from: maskHandler
    )

    guard let outline = try Self.traceOutline(fromMask: maskPixelBuffer) else { return nil }

    // Background-removed, tightly cropped image of just the object — this is
    // what classification/fallback OCR run on, not the original (background-including) crop.
    let isolatedObjectBuffer = try maskObservation.generateMaskedImage(
      ofInstances: maskObservation.allInstances, from: maskHandler, croppedToInstancesExtent: true
    )

    return ObjectFoundation(
      outline: outline,
      boundingBox: outline.path.boundingBox,
      isolatedObjectBuffer: isolatedObjectBuffer,
      shapeFeatures: Self.shapeFeatures(for: outline.path),
      dominantColor: Self.dominantColor(in: isolatedObjectBuffer)
    )
  }

  /// Classifies the general contents of an image (e.g. "bottle", "cheese",
  /// "telephone") using Vision's built-in classifier — no bundled/downloaded
  /// model required. Returns the top candidates, most confident first.
  func classifyObject(in image: UIImage) async throws -> [ObjectClassification] {
    guard let cgImage = image.cgImage else { return [] }

    let handler = VNImageRequestHandler(
      cgImage: cgImage,
      orientation: image.imageOrientation.cgImagePropertyOrientation
    )
    return try await classifyObject(using: handler)
  }

  /// Classifies an already-isolated object image (see `detectObjectFoundation`).
  func classifyObject(inPixelBuffer pixelBuffer: CVPixelBuffer) async throws -> [ObjectClassification] {
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
    return try await classifyObject(using: handler)
  }

  private func classifyObject(using handler: VNImageRequestHandler) async throws -> [ObjectClassification] {
    let request = VNClassifyImageRequest()
    try handler.perform([request])

    return (request.results ?? [])
      .sorted { $0.confidence > $1.confidence }
      .map { ObjectClassification(identifier: $0.identifier, confidence: $0.confidence) }
  }

  /// Traces the edge of a foreground mask into a drawable, normalized outline.
  private static func traceOutline(fromMask maskPixelBuffer: CVPixelBuffer) throws -> ObjectOutline? {
    let contourRequest = VNDetectContoursRequest()
    contourRequest.detectsDarkOnLight = false
    contourRequest.contrastAdjustment = 2.0
    // Default is 512; the scaled mask can be much larger, so raise this to
    // actually take advantage of the extra resolution instead of Vision
    // downscaling it back down before tracing the contour.
    contourRequest.maximumImageDimension = 1536

    let contourHandler = VNImageRequestHandler(cvPixelBuffer: maskPixelBuffer, orientation: .up)
    try contourHandler.perform([contourRequest])

    guard
      let contoursObservation = contourRequest.results?.first,
      let largestContour = contoursObservation.topLevelContours.max(by: { $0.pointCount < $1.pointCount })
    else {
      return nil
    }

    // Simplify the raw per-pixel trace into a cleaner polygon for smoother
    // drawing — a smaller epsilon than before since the higher-res mask has
    // enough real detail now to keep curves looking round, not faceted.
    let simplified = (try? largestContour.polygonApproximation(epsilon: 0.003)) ?? largestContour

    return ObjectOutline(path: simplified.normalizedPath)
  }

  /// Computes aspect ratio + circularity from the outline's polygon points.
  /// Area/perimeter use the shoelace formula on the (already-simplified)
  /// contour points — circularity is scale-invariant, so this works fine
  /// directly on Vision's normalized (unit-square) coordinates.
  private static func shapeFeatures(for path: CGPath) -> ObjectShapeFeatures {
    let boundingBox = path.boundingBox
    let aspectRatio = boundingBox.height > 0 ? boundingBox.width / boundingBox.height : 1

    var points: [CGPoint] = []
    path.applyWithBlock { elementPointer in
      let element = elementPointer.pointee
      switch element.type {
      case .moveToPoint, .addLineToPoint:
        points.append(element.points[0])
      default:
        break
      }
    }

    guard points.count >= 3 else {
      return ObjectShapeFeatures(aspectRatio: aspectRatio, circularity: 0)
    }

    var area: CGFloat = 0
    var perimeter: CGFloat = 0
    for index in points.indices {
      let current = points[index]
      let next = points[(index + 1) % points.count]
      area += current.x * next.y - next.x * current.y
      perimeter += hypot(next.x - current.x, next.y - current.y)
    }
    area = abs(area) / 2

    let circularity = perimeter > 0 ? min(1, (4 * .pi * area) / (perimeter * perimeter)) : 0
    return ObjectShapeFeatures(aspectRatio: aspectRatio, circularity: circularity)
  }

  private static let ciContext = CIContext()

  /// Average color over the whole pixel buffer via Core Image's built-in
  /// reduction filter — cheap (one GPU pass, no per-pixel Swift loop).
  private static func dominantColor(in pixelBuffer: CVPixelBuffer) -> UIColor? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
    guard let outputImage = filter.outputImage else { return nil }

    var bitmap = [UInt8](repeating: 0, count: 4)
    ciContext.render(
      outputImage,
      toBitmap: &bitmap,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: nil
    )
    return UIColor(
      red: CGFloat(bitmap[0]) / 255,
      green: CGFloat(bitmap[1]) / 255,
      blue: CGFloat(bitmap[2]) / 255,
      alpha: CGFloat(bitmap[3]) / 255
    )
  }
}

extension UIImage.Orientation {
  var cgImagePropertyOrientation: CGImagePropertyOrientation {
    switch self {
    case .up: return .up
    case .upMirrored: return .upMirrored
    case .down: return .down
    case .downMirrored: return .downMirrored
    case .left: return .left
    case .leftMirrored: return .leftMirrored
    case .right: return .right
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
  }
}
