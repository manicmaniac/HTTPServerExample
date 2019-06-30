//
//  HTTPServer.swift
//  HTTPServerExample
//
//  Created by Ryosuke Ito on 6/21/19.
//  Copyright © 2019 Ryosuke Ito. All rights reserved.
//

import Foundation

public enum HTTPServerState {
    case idle
    case starting
    case running
    case stopping
}

public enum HTTPServerError: Error, CustomNSError {
    public static let domain: NSErrorDomain = "HTTPServerError"

    case socketCreationFailed
    case socketSetOptionFailed
    case socketSetAddressFailed
    case socketSetAddressTimeout
    case socketListenFailed
}

public protocol HTTPRequestHandler: class {
    func server(_ server: HTTPServer, didReceiveRequest request: CFHTTPMessage, fileHandle: FileHandle, completion: @escaping () -> Void)
}

public protocol HTTPServerDelegate: class {
    func serverDidChangeState(_ server: HTTPServer)
}

public class HTTPServer {
    public private(set) var state = HTTPServerState.idle {
        didSet { delegate?.serverDidChangeState(self) }
    }
    public weak var requestHandler: HTTPRequestHandler?
    public weak var delegate: HTTPServerDelegate?
    private var listeningHandle: FileHandle?
    private var socket: CFSocket?
    private var incomingRequests = [FileHandle: CFHTTPMessage]()

    public func start(port: UInt16) throws {
        state = .starting
        guard let socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, nil, nil) else {
            throw HTTPServerError.socketCreationFailed
        }
        self.socket = socket

        var reuse = 1
        let fileDescriptor = CFSocketGetNative(socket)
        if setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int>.size)) != 0 {
            throw HTTPServerError.socketSetOptionFailed
        }
        var noSigPipe = 1
        if setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int>.size)) != 0 {
            throw HTTPServerError.socketSetOptionFailed
        }
        var address = sockaddr_in(sin_len: __uint8_t(MemoryLayout<sockaddr_in>.size),
                                  sin_family: sa_family_t(AF_INET),
                                  sin_port: port.bigEndian,
                                  sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let addressData = Data(bytes: &address, count: MemoryLayout<sockaddr_in>.size)
        switch CFSocketSetAddress(socket, addressData as CFData) {
        case .success:
            break
        case .error:
            throw HTTPServerError.socketSetAddressFailed
        case .timeout:
            throw HTTPServerError.socketSetAddressTimeout
        }
        if listen(fileDescriptor, 5) != 0 {
            throw HTTPServerError.socketListenFailed
        }
        let listeningHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        self.listeningHandle = listeningHandle
        NotificationCenter.default.addObserver(self, selector: #selector(receiveIncomingConnectionNotification(_:)), name: .NSFileHandleConnectionAccepted, object: listeningHandle)
        listeningHandle.acceptConnectionInBackgroundAndNotify()
        state = .running
    }

    public func stop() {
        state = .stopping
        NotificationCenter.default.removeObserver(self, name: .NSFileHandleConnectionAccepted, object: nil)
        listeningHandle?.closeFile()
        listeningHandle = nil
        for incomingFileHandle in incomingRequests.keys {
            stopReceiving(for: incomingFileHandle, close: true)
        }
        if let socket = socket {
            CFSocketInvalidate(socket)
        }
        socket = nil
        state = .idle
    }

    private func stopReceiving(for incomingFileHandle: FileHandle, close closeFileHandle: Bool) {
        if closeFileHandle {
            incomingFileHandle.closeFile()
        }
        NotificationCenter.default.removeObserver(self, name: .NSFileHandleDataAvailable, object: incomingFileHandle)
        incomingRequests.removeValue(forKey: incomingFileHandle)
    }

    @objc private func receiveIncomingConnectionNotification(_ notification: Notification) {
        if let incomingFileHandle = notification.userInfo?[NSFileHandleNotificationFileHandleItem] as? FileHandle {
            let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true)
            incomingRequests[incomingFileHandle] = message.autorelease().takeUnretainedValue()
            NotificationCenter.default.addObserver(self, selector: #selector(receiveIncomingDataNotification(_:)), name: .NSFileHandleDataAvailable, object: incomingFileHandle)
            incomingFileHandle.waitForDataInBackgroundAndNotify()
        }
        listeningHandle?.acceptConnectionInBackgroundAndNotify()
    }

    @objc private func receiveIncomingDataNotification(_ notification: Notification) {
        guard let incomingFileHandle = notification.object as? FileHandle else { return }
        var data = incomingFileHandle.availableData
        guard !data.isEmpty else {
            return stopReceiving(for: incomingFileHandle, close: false)
        }
        guard let incomingRequest = incomingRequests[incomingFileHandle] else {
            return stopReceiving(for: incomingFileHandle, close: true)
        }
        guard data.withUnsafeBytes({ bytes in CFHTTPMessageAppendBytes(incomingRequest, bytes, data.count) }) else {
            return stopReceiving(for: incomingFileHandle, close: true)
        }
        guard CFHTTPMessageIsHeaderComplete(incomingRequest) else {
            return incomingFileHandle.waitForDataInBackgroundAndNotify()
        }
        defer { stopReceiving(for: incomingFileHandle, close: false) }
        requestHandler?.server(self, didReceiveRequest: incomingRequest, fileHandle: incomingFileHandle) { [weak self] in
            self?.stopReceiving(for: incomingFileHandle, close: true)
        }
    }
}
