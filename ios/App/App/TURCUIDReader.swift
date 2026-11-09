import Foundation
import CoreNFC

// Only factory identification is read. The sole transceive is NXP GET_VERSION (0x60).
final class TURCUIDReader: NSObject, NFCTagReaderSessionDelegate {
    var singleRead = false
    var onRead: ((String) -> Void)?
    var onFinish: ((String?) -> Void)?
    private var session: NFCTagReaderSession?
    private var finished = false
    private var reading = false
    func begin() {
        guard let reader = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
            finish("NFC UID reading could not start. Check the TAG entitlement in your signed app."); return
        }
        session = reader
        reader.alertMessage = singleRead ? "Hold the selected student's NTAG215 sticker near the top of your iPhone to read its UID." : "Hold a runner's assigned NTAG215 near the top of your iPhone."
        reader.begin()
    }
    func message(_ text: String) { session?.alertMessage = text }
    func cancel() { session?.invalidate(); finish("NFC session closed. Tap NFC to start again.") }
    private func finish(_ error: String?) {
        guard !finished else { return }; finished = true
        let completion = onFinish; session = nil
        DispatchQueue.main.async { completion?(error) }
    }
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard !finished else { return }
        if (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorUserCanceled { finish(singleRead ? "Sticker scan canceled. No assignment was changed." : nil) }
        else { finish("NFC UID session ended. Restart NFC or check the TAG entitlement. " + error.localizedDescription) }
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard !finished, !reading else { return }
        guard tags.count == 1, let tag = tags.first else { session.alertMessage = "Present one sticker at a time.";session.restartPolling();return }
        guard case let .miFare(mifare) = tag, mifare.identifier.count == 7 else {
            session.alertMessage = "Use an NTAG215 sticker with a seven-byte factory UID."; session.restartPolling(); return
        }
        reading = true
        session.connect(to: tag) { [weak self] error in
            guard let self = self, !self.finished else { return }
            if let error = error { self.fail(session,error.localizedDescription); return }
            mifare.sendMiFareCommand(commandPacket: Data([0x60])) { response, error in
                DispatchQueue.main.async {
                    guard !self.finished else { return }
                    guard error == nil, response.count == 8, response[1] == 0x04, response[2] == 0x04, response[6] == 0x11 else {
                        self.fail(session,"This sticker could not be identified as NTAG215. No assignment was changed.");return
                    }
                    let uid = mifare.identifier.map { String(format: "%02X", $0) }.joined()
                    self.onRead?(uid)
                    if self.singleRead { session.alertMessage = "UID read successfully."; session.invalidate(); self.finish(nil) }
                    else { self.reading = false; session.restartPolling() }
                }
            }
        }
    }
    private func fail(_ session: NFCTagReaderSession,_ error: String) { session.invalidate(errorMessage:error);finish(error) }
}
