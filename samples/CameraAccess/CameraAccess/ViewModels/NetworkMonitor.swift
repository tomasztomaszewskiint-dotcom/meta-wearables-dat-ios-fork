//
//  NetworkMonitor.swift
//  CameraAccess
//

import Network
import Observation

/// Observes device connectivity so product lookups can check reachability
/// up front instead of waiting on a request to time out.
@Observable
final class NetworkMonitor {
  private(set) var isConnected: Bool = true

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.cameraaccess.networkmonitor")

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let connected = path.status == .satisfied
      DispatchQueue.main.async {
        self?.isConnected = connected
      }
    }
    monitor.start(queue: queue)
  }

  deinit {
    monitor.cancel()
  }
}
