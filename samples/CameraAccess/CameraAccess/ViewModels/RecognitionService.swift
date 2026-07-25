//
//  RecognitionService.swift
//  CameraAccess
//
//  Created by Tomasz Tomaszewski on 23/07/2026.
//

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

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(
      cgImage: cgImage,
      orientation: image.imageOrientation.cgImagePropertyOrientation
    )
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

  /// Classifies the general contents of an image (e.g. "bottle", "cheese",
  /// "telephone") using Vision's built-in classifier — no bundled/downloaded
  /// model required. Returns the top candidates, most confident first.
  func classifyObject(in image: UIImage) async throws -> [ObjectClassification] {
    guard let cgImage = image.cgImage else { return [] }

    let request = VNClassifyImageRequest()

    let handler = VNImageRequestHandler(
      cgImage: cgImage,
      orientation: image.imageOrientation.cgImagePropertyOrientation
    )
    try handler.perform([request])

    return (request.results ?? [])
      .sorted { $0.confidence > $1.confidence }
      .map { ObjectClassification(identifier: $0.identifier, confidence: $0.confidence) }
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
