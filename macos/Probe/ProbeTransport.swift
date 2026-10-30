import Foundation

/// After start(), request state is confined to URLSession's serial delegate
/// queue. The session handle has its own lock for CLI watchdog cancellation.
/// The completion delivers an immutable result; UI work dispatches to main.
final class ProbeFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let target: ProbeTarget
    private let completion: @Sendable (ProbeResult) -> Void
    private let sessionLock = NSLock()
    private var session: URLSession?
    private var started: TimeInterval = 0
    private var startedAt = ""
    private var received = 0
    private var status: Int?
    private var refusal: String?
    private var evidence = ProbeTransportEvidence()

    init(target: ProbeTarget, completion: @escaping @Sendable (ProbeResult) -> Void) {
        self.target = target; self.completion = completion
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 1
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        sessionLock.lock()
        self.session = session
        sessionLock.unlock()
        var request = URLRequest(url: target.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        request.setValue("close", forHTTPHeaderField: "Connection")
        started = ProcessInfo.processInfo.systemUptime
        startedAt = probeTimestamp()
        session.dataTask(with: request).resume()
    }

    func cancel() {
        sessionLock.lock()
        let current = session
        sessionLock.unlock()
        current?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        refusal = "redirect_refused"
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }

    private func answer(_ challenge: URLAuthenticationChallenge,
                        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep normal OS TLS trust validation; never use HTTP or client-cert
        // credentials, even if the machine's keychain contains them.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            refusal = "authentication_refused"
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        // No body is retained or printed; bound the amount fetched as well.
        if received > 65_536 { refusal = "response_limit"; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        evidence.transactions = metrics.transactionMetrics.count
        if let transaction = metrics.transactionMetrics.last {
            evidence.protocolName = transaction.networkProtocolName
            evidence.tls = transaction.negotiatedTLSProtocolVersion != nil
            evidence.reused = transaction.isReusedConnection
            evidence.proxy = transaction.isProxyConnection
            evidence.networkLoad = transaction.resourceFetchType == .networkLoad
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = error.map { ($0 as NSError).code }
        let outcome = ProbeResult.classify(errorCode: code, refusal: refusal, status: status, evidence: evidence)
        let result = ProbeResult(label: target.label, host: target.url.host ?? "unavailable", outcome: outcome,
            status: status, networkProtocol: evidence.protocolName, tls: evidence.tls, freshTCP: evidence.verifiedTCP,
            bytes: received, durationMS: Int((ProcessInfo.processInfo.systemUptime - started) * 1000), errorCode: code,
            startedAt: startedAt, completedAt: probeTimestamp())
        session.finishTasksAndInvalidate()
        sessionLock.lock()
        self.session = nil
        sessionLock.unlock()
        completion(result)
    }
}
