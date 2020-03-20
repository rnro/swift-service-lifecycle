//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftServiceLauncher open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the SwiftServiceLauncher project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftServiceLauncher project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import Backtrace
import Dispatch
import Logging

/// `Lifecycle` provides a basic mechanism to cleanly startup and shutdown the application, freeing resources in order before exiting.
public class Lifecycle {
    private let logger = Logger(label: "\(Lifecycle.self)")
    private let shutdownGroup = DispatchGroup()

    private var state = State.idle
    private let stateSemaphore = DispatchSemaphore(value: 1)

    private var items = [LifecycleItem]()
    private let itemsSemaphore = DispatchSemaphore(value: 1)

    /// Creates a `Lifecycle` instance.
    public init() {
        self.shutdownGroup.enter()
    }

    /// Starts the provided `LifecycleItem` array and waits (blocking) until a shutdown `Signal` is captured or `Lifecycle.shutdown` is called on another thread.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    public func startAndWait(configuration: Configuration) throws {
        let waitSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        let items = self.itemsSemaphore.lock { self.items }
        self._start(configuration: configuration, items: items) { error in
            startError = error
            waitSemaphore.signal()
        }
        waitSemaphore.wait()
        try startError.map { throw $0 }
        self.shutdownGroup.wait()
    }

    /// Starts the provided `LifecycleItem` array.
    /// Startup is performed in the order of items provided.
    ///
    /// - parameters:
    ///    - configuration: Defines lifecycle `Configuration`
    ///    - callback: The handler which is called after the start operation completes. The parameter will be `nil` on success and contain the `Error` otherwise.
    public func start(configuration: Configuration, callback: @escaping (Error?) -> Void) {
        let items = self.itemsSemaphore.lock { self.items }
        self._start(configuration: configuration, items: items, callback: callback)
    }

    /// Shuts down the `LifecycleItem` array provided in `start` or `startAndWait`.
    /// Shutdown is performed in reverse order of items provided.
    public func shutdown(on queue: DispatchQueue = DispatchQueue.global()) {
        self.stateSemaphore.wait()
        switch self.state {
        case .idle:
            self.stateSemaphore.signal()
            self.shutdownGroup.leave()
        case .starting:
            self.state = .shuttingDown
            self.stateSemaphore.signal()
        case .shuttingDown, .shutdown:
            self.stateSemaphore.signal()
            return
        case .started(let items):
            self.state = .shuttingDown
            self.stateSemaphore.signal()
            self._shutdown(on: queue, items: items) {
                self.shutdownGroup.leave()
            }
        }
    }

    /// Waits (blocking) until shutdown signal is captured or `Lifecycle.shutdown` is invoked on another thread.
    public func wait() {
        self.shutdownGroup.wait()
    }

    // MARK: - private

    private func _start(configuration: Configuration, items: [LifecycleItem], callback: @escaping (Error?) -> Void) {
        self.stateSemaphore.lock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
            precondition(items.count > 0, "invalid number of items, must be > 0")
            self.logger.info("starting lifecycle")
            if configuration.installBacktrace {
                self.logger.info("installing backtrace")
                Backtrace.install()
            }
            self.state = .starting
        }
        self._start(on: configuration.callbackQueue, items: items, index: 0) { _, error in
            self.stateSemaphore.wait()
            if error != nil {
                self.state = .shuttingDown
            }
            switch self.state {
            case .shuttingDown:
                self.stateSemaphore.signal()
                // shutdown was called while starting, or start failed, shutdown what we can
                self._shutdown(on: configuration.callbackQueue, items: items) {
                    callback(error)
                    self.shutdownGroup.leave()
                }
            case .starting:
                self.state = .started(items)
                self.stateSemaphore.signal()
                configuration.shutdownSignal?.forEach { signal in
                    self.logger.info("setting up shutdown hook on \(signal)")
                    let signalSource = Lifecycle.trap(signal: signal, handler: { signal in
                        self.logger.info("intercepted signal: \(signal)")
                        self.shutdown(on: configuration.callbackQueue)
                    })
                    self.shutdownGroup.notify(queue: DispatchQueue.global()) {
                        signalSource.cancel()
                    }
                }
                return callback(nil)
            default:
                preconditionFailure("invalid state, \(self.state)")
            }
        }
    }

    private func _start(on queue: DispatchQueue, items: [LifecycleItem], index: Int, callback: @escaping (Int, Error?) -> Void) {
        // async barrier
        let start = { (callback) -> Void in queue.async { items[index].start(callback: callback) } }
        let callback = { (index, error) -> Void in queue.async { callback(index, error) } }

        if index >= items.count {
            return callback(index, nil)
        }
        self.logger.info("starting item [\(items[index].name)]")
        start { error in
            if let error = error {
                self.logger.info("failed to start [\(items[index].name)]: \(error)")
                return callback(index, error)
            }
            // shutdown called while starting
            self.stateSemaphore.wait()
            if case .shuttingDown = self.state {
                self.stateSemaphore.signal()
                return callback(index, nil)
            }
            self.stateSemaphore.signal()
            self._start(on: queue, items: items, index: index + 1, callback: callback)
        }
    }

    private func _shutdown(on queue: DispatchQueue, items: [LifecycleItem], callback: @escaping () -> Void) {
        self.stateSemaphore.lock {
            self.logger.info("shutting down lifecycle")
            self.state = .shuttingDown
        }
        self._shutdown(on: queue, items: items.reversed(), index: 0) {
            self.stateSemaphore.lock {
                guard case .shuttingDown = self.state else {
                    preconditionFailure("invalid state, \(self.state)")
                }
                self.state = .shutdown
            }
            self.logger.info("bye")
            callback()
        }
    }

    private func _shutdown(on queue: DispatchQueue, items: [LifecycleItem], index: Int, callback: @escaping () -> Void) {
        // async barrier
        let shutdown = { (callback) -> Void in queue.async { items[index].shutdown(callback: callback) } }
        let callback = { () -> Void in queue.async { callback() } }

        if index >= items.count {
            return callback()
        }
        self.logger.info("stopping item [\(items[index].name)]")
        shutdown { error in
            if let error = error {
                self.logger.info("failed to stop [\(items[index].name)]: \(error)")
            }
            self._shutdown(on: queue, items: items, index: index + 1, callback: callback)
        }
    }

    private enum State {
        case idle
        case starting
        case started([LifecycleItem])
        case shuttingDown
        case shutdown
    }
}

extension Lifecycle {
    internal struct Item: LifecycleItem {
        public let name: String
        private let _start: FunctionWithCallback?
        private let _shutdown: FunctionWithCallback

        init(name: String, start: FunctionWithCallback?, shutdown: @escaping FunctionWithCallback) {
            self.name = name
            self._start = start
            self._shutdown = shutdown
        }

        init(name: String, start: FunctionWithCallback?, shutdown: @escaping ThrowingFunction) {
            self.name = name
            self._start = start
            self._shutdown = Item.callback(shutdown)
        }

        init<Future, Value>(name: String, start: FunctionWithCallback?, shutdown: @escaping FutureProvider<Future, Value>) {
            self.name = name
            self._start = start
            self._shutdown = Item.callback(shutdown)
        }

        init(name: String, start: ThrowingFunction?, shutdown: @escaping FunctionWithCallback) {
            self.name = name
            self._start = start.map(Item.callback)
            self._shutdown = shutdown
        }

        init(name: String, start: ThrowingFunction?, shutdown: @escaping ThrowingFunction) {
            self.name = name
            self._start = start.map(Item.callback)
            self._shutdown = Item.callback(shutdown)
        }

        init<Future, Value>(name: String, start: ThrowingFunction?, shutdown: @escaping FutureProvider<Future, Value>) {
            self.name = name
            self._start = start.map(Item.callback)
            self._shutdown = Item.callback(shutdown)
        }

        init<Future, Value>(name: String, start: FutureProvider<Future, Value>?, shutdown: @escaping FunctionWithCallback) {
            self.name = name
            self._start = start.map(Item.callback)
            self._shutdown = shutdown
        }

        init<Future, Value>(name: String, start: FutureProvider<Future, Value>?, shutdown: @escaping ThrowingFunction) {
            self.name = name
            self._start = start.map(Item.callback)
            self._shutdown = Item.callback(shutdown)
        }

        init<Future, Value>(name: String, start: FutureProvider<Future, Value>?, shutdown: @escaping FutureProvider<Future, Value>) {
            self.name = name
            self._start = start.map(Item.callback)
            self._shutdown = Item.callback(shutdown)
        }

        func start(callback: @escaping (Error?) -> Void) {
            if let body = self._start {
                body(callback)
            } else {
                callback(nil)
            }
        }

        func shutdown(callback: @escaping (Error?) -> Void) {
            self._shutdown(callback)
        }

        private static func callback(_ body: @escaping ThrowingFunction) -> FunctionWithCallback {
            return { callback in
                do {
                    try body()
                    callback(nil)
                } catch {
                    callback(error)
                }
            }
        }

        private static func callback<Future, Value>(_ future: @escaping FutureProvider<Future, Value>) -> FunctionWithCallback {
            return { callback in
                future().whenComplete { result in
                    switch result {
                    case .success:
                        callback(nil)
                    case .failure(let error):
                        callback(error)
                    }
                }
            }
        }
    }
}

extension Lifecycle {
    /// `Lifecycle` configuration options.
    public struct Configuration {
        /// Defines the `DispatchQueue` on which startup and shutdown handlers are executed.
        public let callbackQueue: DispatchQueue
        /// Defines if to install a crash signal trap that prints backtraces.
        public let shutdownSignal: [Signal]?
        /// Defines what, if any, signals to trap for invoking shutdown.
        public let installBacktrace: Bool

        public init(callbackQueue: DispatchQueue = DispatchQueue.global(),
                    shutdownSignal: [Signal]? = [.TERM, .INT],
                    installBacktrace: Bool = true) {
            self.callbackQueue = callbackQueue
            self.shutdownSignal = shutdownSignal
            self.installBacktrace = installBacktrace
        }
    }
}

/// Adding items
public extension Lifecycle {
    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - items: one or more `LifecycleItem`.
    internal func append(_ items: LifecycleItem...) {
        self.stateSemaphore.lock {
            guard case .idle = self.state else {
                preconditionFailure("invalid state, \(self.state)")
            }
        }
        self.itemsSemaphore.lock {
            items.forEach { self.items.append($0) }
        }
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - items: one or more `LifecycleItem`.
    func append(_ items: [LifecycleItem]) {
        items.forEach { self.append($0) }
    }

    /// Add a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append(name: String, start: @escaping FunctionWithCallback, shutdown: @escaping FunctionWithCallback) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func append(name: String, shutdown: @escaping FunctionWithCallback) {
        self.append(Item(name: name, start: nil as FunctionWithCallback?, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append(name: String, start: @escaping FunctionWithCallback, shutdown: @escaping ThrowingFunction) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func append(name: String, shutdown: @escaping ThrowingFunction) {
        self.append(Item(name: name, start: nil as ThrowingFunction?, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append<Future, Value>(name: String, start: @escaping FunctionWithCallback, shutdown: @escaping FutureProvider<Future, Value>) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func append<Future, Value>(name: String, shutdown: @escaping FutureProvider<Future, Value>) {
        self.append(Item(name: name, start: nil as FutureProvider<Future, Value>?, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append(name: String, start: @escaping ThrowingFunction, shutdown: @escaping FunctionWithCallback) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func append(name: String, start: @escaping ThrowingFunction, shutdown: @escaping ThrowingFunction) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append<Future, Value>(name: String, start: @escaping ThrowingFunction, shutdown: @escaping FutureProvider<Future, Value>) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - shutdown: closure to perform the shutdown.
    func append<Future, Value>(name: String, start: @escaping FutureProvider<Future, Value>, shutdown: @escaping FunctionWithCallback) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Add a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append<Future, Value>(name: String, start: @escaping FutureProvider<Future, Value>, shutdown: @escaping ThrowingFunction) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }

    /// Adds a `LifecycleItem` to a `LifecycleItems` collection.
    ///
    /// - parameters:
    ///    - name: name of the item, useful for debugging.
    ///    - start: closure to perform the startup.
    ///    - shutdown: closure to perform the shutdown.
    func append<Future, Value>(name: String, start: @escaping FutureProvider<Future, Value>, shutdown: @escaping FutureProvider<Future, Value>) {
        self.append(Item(name: name, start: start, shutdown: shutdown))
    }
}

/// Supported startup and shutdown method styles

public extension Lifecycle {
    typealias FunctionWithCallback = (@escaping (Error?) -> Void) -> Void
    typealias ThrowingFunction = () throws -> Void
    typealias FutureProvider<Future: LifecycleFuture, Value> = () -> Future where Future.Value == Value
}

public protocol LifecycleFuture {
    associatedtype Value

    func whenComplete(_ callback: @escaping (Result<Value, Error>) -> Void)
}

/// Represents an item that can be started and shut down
public protocol LifecycleItem {
    var name: String { get }
    func start(callback: @escaping (Error?) -> Void)
    func shutdown(callback: @escaping (Error?) -> Void)
}

extension Lifecycle {
    /// Setup a signal trap.
    ///
    /// - parameters:
    ///    - signal: The signal to trap.
    ///    - handler: closure to invoke when the signal is captured.
    /// - returns: a `DispatchSourceSignal` for the given trap. The source must be cancled by the caller.
    public static func trap(signal sig: Signal, handler: @escaping (Signal) -> Void, queue: DispatchQueue = DispatchQueue.global()) -> DispatchSourceSignal {
        let signalSource = DispatchSource.makeSignalSource(signal: sig.rawValue, queue: queue)
        signal(sig.rawValue, SIG_IGN)
        signalSource.setEventHandler(handler: {
            signalSource.cancel()
            handler(sig)
        })
        signalSource.resume()
        return signalSource
    }

    /// A system signal
    public struct Signal {
        internal var rawValue: CInt

        public static let TERM: Signal = Signal(rawValue: SIGTERM)
        public static let INT: Signal = Signal(rawValue: SIGINT)
        // for testing
        internal static let ALRM: Signal = Signal(rawValue: SIGALRM)
    }
}

private extension DispatchSemaphore {
    func lock<T>(_ body: () -> T) -> T {
        self.wait()
        defer { self.signal() }
        return body()
    }
}