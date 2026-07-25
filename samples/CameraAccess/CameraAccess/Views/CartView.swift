/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CartView.swift
//
// Lists items added to the (demo-only, in-memory) cart while streaming.
//

import SwiftUI

struct CartView: View {
  var cartStore: CartStore

  var body: some View {
    NavigationView {
      Group {
        if cartStore.items.isEmpty {
          ContentUnavailableView(
            "Your cart is empty",
            systemImage: "cart",
            description: Text("Tap \"Buy\" on a recognized product while streaming to add it here.")
          )
        } else {
          List {
            ForEach(cartStore.items) { item in
              VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                  .font(.body)
                if let quantity = item.quantity {
                  Text(quantity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 2)
            }
            .onDelete { indexSet in
              for index in indexSet {
                cartStore.remove(cartStore.items[index])
              }
            }
          }
        }
      }
      .navigationTitle("Cart (\(cartStore.items.count))")
    }
  }
}
