//
//  DocumentPicker.swift
//  VOIDCORE VPN (Runner)
//
//  Wraps UIDocumentPickerViewController so the Flutter `pickFile` method can
//  present the system file picker and return the chosen file's name and
//  contents to the Dart side. iOS limits the picker to file types the app
//  declares in its Info.plist UTType conformance; we accept JSON, text and
//  octet-stream.
//

import UIKit
import UniformTypeIdentifiers

final class DocumentPicker: NSObject {
    static let shared = DocumentPicker()

    private var completion: ((String, String)?) -> Void?

    func present(completion: @escaping (String, String)?) {
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first?.rootViewController })
            .first else {
            completion(nil)
            return
        }
        self.completion = completion

        let types: [UTType] = [
            UTType.json,
            UTType.plainText,
            UTType.data,
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        rootVC.present(picker, animated: true)
    }
}

extension DocumentPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            completion?(nil); return
        }
        let name = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            if data.count > (1 << 20) {
                completion?(nil); return
            }
            let content = String(data: data, encoding: .utf8) ?? ""
            completion?((name, content))
        } catch {
            completion?(nil)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion?(nil)
    }
}
