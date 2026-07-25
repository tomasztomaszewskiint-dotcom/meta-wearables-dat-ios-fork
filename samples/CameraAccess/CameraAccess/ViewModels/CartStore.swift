//
//  CartStore.swift
//  CameraAccess
//

import Foundation
import Observation

struct CartItem: Identifiable {
  let id = UUID()
  let barcode: String
  let name: String
  let quantity: String?
  let addedAt: Date
}

/// In-memory shopping cart for this demo — items added while streaming,
/// cleared when the app restarts. No real checkout/payment is implemented.
@Observable
@MainActor
final class CartStore {
  private(set) var items: [CartItem] = []

  func add(barcode: String, name: String, quantity: String?) {
    items.append(CartItem(barcode: barcode, name: name, quantity: quantity, addedAt: Date()))
  }

  func remove(_ item: CartItem) {
    items.removeAll { $0.id == item.id }
  }
}
