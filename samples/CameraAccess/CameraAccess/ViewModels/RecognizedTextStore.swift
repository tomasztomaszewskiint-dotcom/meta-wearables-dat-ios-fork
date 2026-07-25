//
//  RecognizedTextStore.swift
//  CameraAccess
//

import Foundation
import SwiftData

/// Persists recognized text clusters to SwiftData, de-duplicating repeat
/// sightings of the same text within a short window — the OCR pass re-reads
/// whatever's still inside the reticle roughly every 0.6s, so without this a
/// sign sitting in frame for a few seconds would be saved dozens of times.
@MainActor
final class RecognizedTextStore {
  private let modelContext: ModelContext
  private var lastSavedAt: [String: Date] = [:]
  private let dedupeWindow: TimeInterval = 1.0

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func record(_ clusters: [ClusteredText], at timestamp: Date = Date()) {
    for cluster in clusters {
      recordLabel(cluster.text, at: timestamp)
    }
  }

  /// Records a single recognized label — an object classification (e.g.
  /// "Bottle") or a barcode payload/resolved product name — using the same
  /// de-duplication as OCR text, so the log reflects whatever's currently
  /// shown on screen (classification badge, barcode/product overlay) without
  /// repeating the same entry every scan cycle.
  func recordLabel(_ text: String, at timestamp: Date = Date()) {
    guard !text.isEmpty else { return }
    if let last = lastSavedAt[text], timestamp.timeIntervalSince(last) < dedupeWindow {
      return
    }
    lastSavedAt[text] = timestamp
    modelContext.insert(RecognizedTextEntry(text: text, timestamp: timestamp))
  }
}
