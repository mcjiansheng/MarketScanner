//
//  PriceTagNFCReader.swift
//  RTABMapApp
//

import Foundation
import CoreNFC

final class PriceTagNFCReader: NSObject, NFCNDEFReaderSessionDelegate {
    private var session: NFCNDEFReaderSession?
    private let completion: (Result<(identifier: String, payload: String), Error>) -> Void

    init(completion: @escaping (Result<(identifier: String, payload: String), Error>) -> Void) {
        self.completion = completion
    }

    func begin() {
        guard NFCNDEFReaderSession.readingAvailable else {
            completion(.failure(NSError(domain: "PriceTagNFCReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "NFC reading is not available on this device."])))
            return
        }
        session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        session?.alertMessage = "Hold iPhone near the electronic price tag."
        session?.begin()
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let nsError = error as NSError
        if nsError.code != NFCReaderError.readerSessionInvalidationErrorFirstNDEFTagRead.rawValue {
            completion(.failure(error))
        }
        self.session = nil
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let records = messages.flatMap { $0.records }
        guard let first = records.first else {
            completion(.failure(NSError(domain: "PriceTagNFCReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "No NDEF payload found."])))
            return
        }

        let identifier = first.identifier.map { String(format: "%02x", $0) }.joined()
        let payload: String
        if let text = decodeTextPayload(first.payload) {
            payload = text
        } else {
            payload = first.payload.map { String(format: "%02x", $0) }.joined()
        }

        completion(.success((identifier.isEmpty ? "ndef-\(Date().timeIntervalSince1970)" : identifier, payload)))
    }

    private func decodeTextPayload(_ data: Data) -> String? {
        guard data.count > 1 else {
            return nil
        }
        let status = data[data.startIndex]
        let languageCodeLength = Int(status & 0x3F)
        let isUTF16 = (status & 0x80) != 0
        let textStart = data.index(data.startIndex, offsetBy: 1 + languageCodeLength)
        guard textStart <= data.endIndex else {
            return nil
        }
        return String(data: Data(data[textStart...]), encoding: isUTF16 ? .utf16 : .utf8)
    }
}
