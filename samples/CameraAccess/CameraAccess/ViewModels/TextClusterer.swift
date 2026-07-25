//
//  TextClusterer.swift
//  CameraAccess
//

import CoreGraphics

/// A group of nearby recognized text observations, merged into one logical
/// piece of text (e.g. the several lines on a single product label).
struct ClusteredText {
  let text: String
  let boundingBox: CGRect
}

/// Groups recognized text observations into clusters using proximity
/// relative to line height: two observations merge if the gap between their
/// bounding boxes (in both axes) is small relative to their own height —
/// mirroring how OCR post-processing typically groups words into blocks.
enum TextClusterer {
  static let mergeGapFactor: CGFloat = 0.6

  static func cluster(_ texts: [RecognizedText]) -> [ClusteredText] {
    guard !texts.isEmpty else { return [] }

    // Reading order: top-to-bottom, then left-to-right. Vision's boundingBox
    // origin is bottom-left, so a larger maxY is higher up on screen.
    let sorted = texts.sorted { lhs, rhs in
      if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.01 {
        return lhs.boundingBox.maxY > rhs.boundingBox.maxY
      }
      return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    var groups: [[RecognizedText]] = []
    for observation in sorted {
      if let lastIndex = groups.indices.last, isClose(observation, to: groups[lastIndex]) {
        groups[lastIndex].append(observation)
      } else {
        groups.append([observation])
      }
    }

    return groups.map { group in
      let text = group.map(\.text).joined(separator: " ")
      let box = union(of: group.map(\.boundingBox))
      return ClusteredText(text: text, boundingBox: box)
    }
  }

  private static func isClose(_ observation: RecognizedText, to group: [RecognizedText]) -> Bool {
    let groupBox = union(of: group.map(\.boundingBox))
    let averageHeight = (observation.boundingBox.height + groupBox.height) / 2
    let threshold = averageHeight * mergeGapFactor

    let horizontalGap = max(0, observation.boundingBox.minX - groupBox.maxX)
    let verticalGap = max(
      groupBox.minY - observation.boundingBox.maxY,
      observation.boundingBox.minY - groupBox.maxY,
      0
    )

    return horizontalGap <= threshold && verticalGap <= threshold
  }

  private static func union(of rects: [CGRect]) -> CGRect {
    guard var result = rects.first else { return .zero }
    for rect in rects.dropFirst() { result = result.union(rect) }
    return result
  }
}
