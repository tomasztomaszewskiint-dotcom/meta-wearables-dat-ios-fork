//
//  RecognizedTextEntry.swift
//  CameraAccess
//

import Foundation
import SwiftData

@Model
final class RecognizedTextEntry {
  var text: String
  var timestamp: Date

  init(text: String, timestamp: Date) {
    self.text = text
    self.timestamp = timestamp
  }
}
