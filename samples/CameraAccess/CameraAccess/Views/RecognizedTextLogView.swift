/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RecognizedTextLogView.swift
//
// Debug-only view listing text recognized from the camera stream and saved
// to SwiftData via `RecognizedTextStore`, newest first.
//

#if DEBUG

import SwiftData
import SwiftUI

struct RecognizedTextLogView: View {
  @Query(sort: \RecognizedTextEntry.timestamp, order: .reverse) private var entries: [RecognizedTextEntry]
  @Environment(\.modelContext) private var modelContext
  @State private var showClearConfirmation = false

  var body: some View {
    NavigationView {
      Group {
        if entries.isEmpty {
          ContentUnavailableView(
            "No recognized text yet",
            systemImage: "text.viewfinder",
            description: Text("Point the camera at some text while streaming to see entries here.")
          )
        } else {
          List(entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.text)
                .font(.body)
              Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }
      }
      .navigationTitle("Recognized Text")
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(role: .destructive) {
            showClearConfirmation = true
          } label: {
            Image(systemName: "trash")
          }
          .disabled(entries.isEmpty)
        }
      }
      .confirmationDialog(
        "Delete all recognized text entries?",
        isPresented: $showClearConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete All", role: .destructive) {
          clearAllEntries()
        }
      }
    }
  }

  private func clearAllEntries() {
    do {
      try modelContext.delete(model: RecognizedTextEntry.self)
    } catch {
      // Non-fatal: this is a debug-only convenience action.
    }
  }
}

#endif
