//
//  DocumentSaver.swift
//  VOIDCORE VPN (Runner)
//
//  Wraps UIDocumentPickerViewController in save mode so the Flutter `saveFile`
//  method can write a JSON export to a user-chosen location (Files app).
//

import UIKit
import UniformTypeIdentifiers

final class DocumentSaver: NSObject {
    static let shared = DocumentSaver()

    private var completion: ((String?) -> Void)?

    func save(name: String, content: String, completion: @escaping (String?) -> Void) {
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first?.rootViewController })
            .first else {
            completion(nil)
            return
        }
        self.completion = completion

        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try content.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            completion(nil); return
        }
        let picker = UIDocumentPickerViewController(forExporting: [tmp], asCopy: true)
        picker.delegate = self
        rootVC.present(picker, animated: true)
    }
}

extension DocumentSaver: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            completion?(url.lastPathComponent)
        } else {
            completion?(nil)
        }
        completion = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion?(nil)
        completion = nil
    }
}
