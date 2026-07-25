//
//  FirestoreSightingService.swift
//  CameraAccess
//

import FirebaseFirestore
import Foundation

/// Mirrors recognized-object "sightings" to Firestore so they can be browsed
/// remotely (Firebase console). Only ever called when an object was actually
/// classified — a bare, context-less piece of recognized text or barcode is
/// never uploaded on its own.
final class FirestoreSightingService {
  static let collectionName = "recognizedObjectSightings"

  private let db = Firestore.firestore()
  private var lastSavedAt: [String: Date] = [:]
  /// Avoids flooding Firestore with a new document every scan cycle while
  /// the same object sits in the reticle — one sighting per label every few seconds.
  private let dedupeWindow: TimeInterval = 3.0

  func saveSighting(
    objectLabel: String,
    objectConfidence: Double,
    recognizedText: String?,
    barcodePayload: String?,
    barcodeSymbology: String?,
    timestamp: Date = Date()
  ) async {
    if let lastSaved = lastSavedAt[objectLabel], timestamp.timeIntervalSince(lastSaved) < dedupeWindow {
      return
    }
    lastSavedAt[objectLabel] = timestamp

    var data: [String: Any] = [
      "objectLabel": objectLabel,
      "objectConfidence": objectConfidence,
      "timestamp": Timestamp(date: timestamp),
    ]
    if let recognizedText { data["recognizedText"] = recognizedText }
    if let barcodePayload { data["barcodePayload"] = barcodePayload }
    if let barcodeSymbology { data["barcodeSymbology"] = barcodeSymbology }

    do {
      let ref = try await db.collection(Self.collectionName).addDocument(data: data)
      NSLog("[FirestoreSightingService] Saved sighting %@ as document %@", objectLabel, ref.documentID)
    } catch {
      // Best-effort for this demo app: offline or Firestore errors just skip the upload.
      NSLog("[FirestoreSightingService] Failed to save sighting for \(objectLabel): \(error)")
    }
  }

  /// Saves a DepthPro size estimate as a "dimensional feature" — explicitly
  /// triggered by the user (the "Estimate Size" action in text-recognition
  /// mode), typically for objects that couldn't be identified any other way,
  /// so this isn't gated behind knowing what the object is.
  func saveDimensionEstimate(
    objectLabel: String?,
    recognizedText: String?,
    widthCm: Double,
    heightCm: Double,
    depthMeters: Double,
    timestamp: Date = Date()
  ) async {
    var data: [String: Any] = [
      "widthCm": widthCm,
      "heightCm": heightCm,
      "depthMeters": depthMeters,
      "timestamp": Timestamp(date: timestamp),
    ]
    if let objectLabel { data["objectLabel"] = objectLabel }
    if let recognizedText { data["recognizedText"] = recognizedText }

    do {
      let ref = try await db.collection("dimensionEstimates").addDocument(data: data)
      NSLog("[FirestoreSightingService] Saved dimension estimate as document %@", ref.documentID)
    } catch {
      NSLog("[FirestoreSightingService] Failed to save dimension estimate: \(error)")
    }
  }
}
