/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// AddToCartView.swift
//
// Sheet shown after tapping "Buy" on a recognized product — confirms
// adding it to the (demo-only, in-memory) cart.
//

import SwiftUI

struct AddToCartView: View {
  let barcode: String
  let details: ProductDetails
  var cartStore: CartStore
  let onDismiss: () -> Void

  var body: some View {
    NavigationView {
      VStack(spacing: 16) {
        VStack(spacing: 6) {
          Text(details.name)
            .font(.title3.bold())
            .multilineTextAlignment(.center)

          if let quantity = details.quantity {
            Text(quantity)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }

          if let grade = details.nutriScore {
            Text("Nutri-Score: \(grade.uppercased())")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.top, 24)

        Spacer()

        CustomButton(title: "Add to Cart", style: .primary, isDisabled: false) {
          cartStore.add(barcode: barcode, name: details.name, quantity: details.quantity)
          onDismiss()
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
      }
      .navigationTitle("Add to Cart")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onDismiss()
          }
        }
      }
    }
  }
}
