//
//  AppDelegate.swift
//  HTTPServerExample
//
//  Created by Ryosuke Ito on 6/21/19.
//  Copyright © 2019 Ryosuke Ito. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var server: HTTPServer!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let server = HTTPServer()
        server.delegate = self
        server.requestHandler = self
        self.server = server
        try! server.start(port: 8081)
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        server.stop()
    }
}

extension AppDelegate: HTTPRequestHandler {
    func server(_ server: HTTPServer, didReceiveRequest request: CFHTTPMessage, fileHandle: FileHandle, completion: @escaping () -> Void) {
        let url = CFHTTPMessageCopyRequestURL(request)!.takeRetainedValue() as URL
        let method = CFHTTPMessageCopyRequestMethod(request)!.takeRetainedValue() as String
        switch (method, url.path) {
        case ("GET", "/"):
            let response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(response, "Content-Type" as CFString, "text/html" as CFString)
            let body = """
<!DOCTYPE html>
<html>
<head>
<title>Hello</title>
</head>
<body>
<h1>HTTP Server is running</h1>
<script>
const eventSource = new EventSource("/events");
eventSource.onmessage = function(e) {
  console.log(e.data);
};
</script>
</body>
</html>
""".data(using: .ascii)!
            CFHTTPMessageSetBody(response, body as CFData)
            assert(CFHTTPMessageIsHeaderComplete(response))
            let data = CFHTTPMessageCopySerializedMessage(response)!.takeRetainedValue() as Data
            fileHandle.write(data)
            completion()
        case ("GET", "/events"):
            let response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(response, "Content-Type" as CFString, "text/event-stream" as CFString)
            CFHTTPMessageSetHeaderFieldValue(response, "Transfer-Encoding" as CFString, "chunked" as CFString)
            CFHTTPMessageSetBody(response, CFDataCreate(kCFAllocatorDefault, "", 0))
            assert(CFHTTPMessageIsHeaderComplete(response))
            let data = CFHTTPMessageCopySerializedMessage(response)!.takeRetainedValue() as Data
            fileHandle.write(data, ignoringBrokenPipe: true)
            var count = 0
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                count += 1
                let data = "8\r\ndata:\(count)\n\n\r\n".data(using: .ascii)!
                fileHandle.write(data, ignoringBrokenPipe: true)
                if count >= 3 {
                    timer.invalidate()
                    let data = "0\r\n\r\n".data(using: .ascii)!
                    fileHandle.write(data, ignoringBrokenPipe: true)
                    completion()
                }
            }
        case ("GET", _):
            let response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 404, nil, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(response, "Content-Type" as CFString, "text/plain" as CFString)
            CFHTTPMessageSetBody(response, "404 Not Found".data(using: .ascii)! as CFData)
            assert(CFHTTPMessageIsHeaderComplete(response))
            let data = CFHTTPMessageCopySerializedMessage(response)!.takeRetainedValue() as Data
            fileHandle.write(data)
            completion()
        default:
            let response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 405, nil, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(response, "Content-Type" as CFString, "text/plain" as CFString)
            CFHTTPMessageSetBody(response, "405 Method Not Allowed".data(using: .ascii)! as CFData)
            assert(CFHTTPMessageIsHeaderComplete(response))
            let data = CFHTTPMessageCopySerializedMessage(response)!.takeRetainedValue() as Data
            fileHandle.write(data)
            completion()
        }
    }
}

extension AppDelegate: HTTPServerDelegate {
    func serverDidChangeState(_ server: HTTPServer) {
        print(server.state)
    }
}
