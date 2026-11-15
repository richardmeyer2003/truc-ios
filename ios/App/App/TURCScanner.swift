import UIKit
import AVFoundation
import CoreNFC
import CoreImage.CIFilterBuiltins
import AudioToolbox
import Capacitor

private func validBadge(_ value: String) -> Bool {
    value.range(of: "^turc:v1:[a-f0-9]{64}$", options: .regularExpression) != nil
}

private func validWalkBib(_ value: String) -> Bool {
    value.range(of: "^wt1:[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil
}

@objc(TURCScannerPlugin)
public final class TURCScannerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TURCScannerPlugin"
    public let jsName = "TURCScanner"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "capabilities", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "feedback", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readTagUID", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "qrImage", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "shareBadgePDF", returnType: CAPPluginReturnPromise)
    ]
    private var scanner: TURCQRController?
    private var nfc: TURCUIDReader?
    private var runID: String?
    private var recent: [String: Date] = [:]
    private var awaitingWalkResult = false
    private var backgroundObserver: NSObjectProtocol?

    public override func load() {
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }
    deinit { if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) } }

    @objc func capabilities(_ call: CAPPluginCall) {
        call.resolve(["camera": UIImagePickerController.isSourceTypeAvailable(.camera), "nfc": NFCTagReaderSession.readingAvailable])
    }
    @objc func open(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let parent = self.bridge?.viewController, self.scanner == nil, parent.presentedViewController == nil else { call.reject("Close the open sheet first"); return }
            let id = call.getString("runID") ?? UUID().uuidString
            let controller = TURCQRController()
            controller.school = call.getString("school") ?? "Your school"
            controller.walkathon = call.getString("mode") == "walkathon"
            controller.useCamera = call.getString("mode") != "nfc"
            controller.onValue = { [weak self] value in self?.emit(value, source: "qr") }
            if !controller.walkathon { controller.onNFC = { [weak self] in self?.readNFC() } }
            controller.onClose = { [weak self] in self?.stop() }
            self.scanner = controller; self.runID = id; self.recent = [:]; self.awaitingWalkResult = false
            controller.modalPresentationStyle = .fullScreen
            parent.present(controller, animated: true) { call.resolve(["runID": id]); if !controller.useCamera { self.readNFC() } }
        }
    }
    private func emit(_ value: String, source: String) {
        guard let id = runID else { return }
        let isWalkathon = scanner?.walkathon == true
        if isWalkathon && awaitingWalkResult { return }
        let valid: Bool
        if isWalkathon { valid = source == "qr" && validWalkBib(value) }
        else { valid = source == "nfc" ? value.range(of: "^[A-F0-9]{14}$", options: .regularExpression) != nil : validBadge(value) }
        guard valid else {
            scanner?.show(isWalkathon ? "Use a Walk-a-thon bib" : "Not a TURC badge",
                          detail: isWalkathon ? "Scan the QR code printed on the event bib." : "Use a QR badge or assigned NTAG215 sticker.", success: false)
            return
        }
        let now = Date()
        let previous = recent[value]
        recent[value] = now
        if let previous = previous, now.timeIntervalSince(previous) < 1.5 { return }
        if recent.count > 300 { recent = recent.filter { now.timeIntervalSince($0.value) < 5 } }
        awaitingWalkResult = isWalkathon
        scanner?.show(isWalkathon ? "Checking lap…" : "Checking badge…", detail: "Waiting for the server", success: nil)
        notifyListeners("scan", data: ["runID": id, "value": value, "source": source, "eventID": UUID().uuidString, "observedAt": ISO8601DateFormatter().string(from: now)])
    }
    private func readNFC() {
        guard nfc == nil, scanner?.walkathon != true else { return }
        guard NFCTagReaderSession.readingAvailable else { scanner?.show("NFC unavailable", detail: "Check your signing method's NFC entitlement. QR is available separately.", success: false); return }
        scanner?.pauseCamera()
        let reader = TURCUIDReader()
        nfc = reader
        reader.onRead = { [weak self] value in self?.emit(value, source: "nfc") }
        reader.onFinish = { [weak self] error in
            self?.nfc = nil; self?.scanner?.resumeCamera()
            if let error = error { self?.scanner?.show("NFC stopped", detail: error, success: false) }
        }
        reader.begin()
    }
    private func stop() {
        let id = runID; runID = nil; awaitingWalkResult = false
        nfc?.cancel(); nfc = nil
        scanner?.shutdown(); scanner?.dismiss(animated: true); scanner = nil
        if let id = id { notifyListeners("closed", data: ["runID": id]) }
    }
    @objc func close(_ call: CAPPluginCall) { DispatchQueue.main.async { [weak self] in self?.stop(); call.resolve() } }
    @objc func feedback(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard call.getString("runID") == self?.runID else { call.resolve(); return }
            let title = String((call.getString("title") ?? "").prefix(120))
            let detail = String((call.getString("detail") ?? "").prefix(240))
            let accepted = call.getBool("accepted") ?? false
            self?.awaitingWalkResult = false
            self?.scanner?.show(title, detail: detail, success: accepted)
            self?.nfc?.message(title + "\n" + detail)
            if accepted { UINotificationFeedbackGenerator().notificationOccurred(.success); AudioServicesPlaySystemSound(1104) }
            call.resolve()
        }
    }
    @objc func readTagUID(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.nfc == nil, self.scanner == nil else { call.reject("Close the scanner before pairing a sticker"); return }
            guard NFCTagReaderSession.readingAvailable else { call.reject("NFC is unavailable. Your signed app needs the NFC Tag Reading entitlement."); return }
            let reader = TURCUIDReader(); self.nfc = reader; reader.singleRead = true
            var scannedUID: String?
            reader.onRead = { uid in scannedUID = uid }
            reader.onFinish = { [weak self] error in
                self?.nfc = nil
                if let error = error { call.reject(error, "NFC_UID") }
                else if let uid = scannedUID { call.resolve(["uid": uid, "tagType": "NTAG215"]) }
                else { call.reject("No sticker UID was read") }
            }
            reader.begin()
        }
    }
    private func image(_ token: String) -> UIImage? {
        guard validBadge(token) else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(token.utf8); filter.correctionLevel = "M"
        guard let code = filter.outputImage, let cg = CIContext().createCGImage(code, from: code.extent) else { return nil }
        // White quiet zone is required for reliable camera decoding.
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: cg).draw(in: CGRect(x: 64, y: 64, width: 512, height: 512))
        }
    }
    @objc func qrImage(_ call: CAPPluginCall) {
        guard let data = image(call.getString("token") ?? "")?.pngData() else { call.reject("QR image could not be created"); return }
        call.resolve(["dataURL": "data:image/png;base64," + data.base64EncodedString()])
    }
    @objc func shareBadgePDF(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let parent = self.bridge?.viewController, parent.presentedViewController == nil else { call.reject("Close the open sheet first"); return }
            let keys = ["token","student_name","student_number","school_name","grade","classroom"]
            let fields = Dictionary(uniqueKeysWithValues: keys.map { ($0,call.getString($0) ?? "") })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("turc-badge-" + UUID().uuidString,isDirectory:true)
            let file = directory.appendingPathComponent("TURC-runner-badge.pdf")
            do {
                let data = try TURCBadgePDF.make(fields)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try data.write(to:file,options:[.atomic,.completeFileProtection])
            } catch { try? FileManager.default.removeItem(at:directory);call.reject("Printable badge could not be created");return }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = parent.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: parent.view.bounds.midX, y: parent.view.bounds.midY, width: 1, height: 1)
            sheet.completionWithItemsHandler = { _,_,_,error in
                try? FileManager.default.removeItem(at:directory)
                if error != nil { call.reject("Printable badge could not be shared") } else { call.resolve() }
            }
            parent.present(sheet, animated: true)
        }
    }
}

private final class TURCQRController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var school = "Your school"
    var useCamera = true
    var walkathon = false
    var onValue: ((String) -> Void)?
    var onNFC: (() -> Void)?
    var onClose: (() -> Void)?
    private let capture = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "org.turc.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var configured = false
    private var closed = false
    private var paused = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor(red: 0.11, green: 0.23, blue: 0.24, alpha: 1)
        let top = UILabel(); top.text = school; top.font = .systemFont(ofSize: 22, weight: .bold); top.textColor = .white; top.textAlignment = .center; top.numberOfLines = 2
        let done = button("Done", action: #selector(doneTapped))
        let header = UIStackView(arrangedSubviews: [top, done]); header.spacing = 12
        let feedback = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight)); feedback.layer.cornerRadius = 28; feedback.clipsToBounds = true
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold); titleLabel.numberOfLines = 2
        detailLabel.font = .systemFont(ofSize: 17); detailLabel.numberOfLines = 4
        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel]); labels.axis = .vertical; labels.spacing = 9
        var modeButtons = [button("Camera QR", action: #selector(cameraTapped))]
        if !walkathon { modeButtons.append(button("NFC stickers", action: #selector(nfcTapped))) }
        let modes = UIStackView(arrangedSubviews: modeButtons); modes.spacing = 12; modes.distribution = .fillEqually
        for child in [header, feedback, modes] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        labels.translatesAutoresizingMaskIntoConstraints = false; feedback.contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20), header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            modes.leadingAnchor.constraint(equalTo: header.leadingAnchor), modes.trailingAnchor.constraint(equalTo: header.trailingAnchor), modes.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18), modes.heightAnchor.constraint(equalToConstant: 56),
            feedback.leadingAnchor.constraint(equalTo: header.leadingAnchor), feedback.trailingAnchor.constraint(equalTo: header.trailingAnchor), feedback.bottomAnchor.constraint(equalTo: modes.topAnchor, constant: -18),
            labels.leadingAnchor.constraint(equalTo: feedback.contentView.leadingAnchor, constant: 22), labels.trailingAnchor.constraint(equalTo: feedback.contentView.trailingAnchor, constant: -22), labels.topAnchor.constraint(equalTo: feedback.contentView.topAnchor, constant: 22), labels.bottomAnchor.constraint(equalTo: feedback.contentView.bottomAnchor, constant: -22)
        ])
        show(walkathon ? "Ready to scan bibs" : "Ready for your runners",
             detail: walkathon ? "Scan the QR on each Walk-a-thon bib. Wait for the lap confirmation before scanning again." : "Present a TURC QR badge or tap NFC stickers. Laps count only after the server confirms them.", success: nil)
        UIApplication.shared.isIdleTimerDisabled = true
        if useCamera { startCamera() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system); var config = UIButton.Configuration.filled(); config.title = title; config.baseBackgroundColor = UIColor(white: 1, alpha: 0.9); config.baseForegroundColor = UIColor(red: 0.13, green: 0.40, blue: 0.37, alpha: 1); config.cornerStyle = .capsule
        button.configuration = config; button.addTarget(self, action: action, for: .touchUpInside); return button
    }
    @objc private func doneTapped() { onClose?() }
    @objc private func cameraTapped() { useCamera = true; startCamera() }
    @objc private func nfcTapped() { onNFC?() }
    private func startCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, !self.closed else { return }
                guard allowed else { self.show("Camera permission needed", detail: "Enable Camera for TURC in iPhone Settings.", success: false); return }
                self.configureCamera()
            }
        }
    }
    private func configureCamera() {
        if configured { resumeCamera(); return }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else { show("Camera unavailable", detail: walkathon ? "Try reopening the scanner." : "Try NFC or reopen the scanner.", success: false); return }
        capture.beginConfiguration(); capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { capture.commitConfiguration(); show("QR scanner unavailable", detail: "Try reopening the scanner.", success: false); return }
        capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]; capture.commitConfiguration(); configured = true
        let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds; view.layer.insertSublayer(layer, at: 0); preview = layer
        resumeCamera()
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !closed, !paused else { return }
        for object in metadataObjects { if let qr = object as? AVMetadataMachineReadableCodeObject, let value = qr.stringValue { onValue?(value) } }
    }
    func pauseCamera() { paused = true; cameraQueue.async { [weak self] in self?.capture.stopRunning() } }
    func resumeCamera() { guard !closed else { return }; paused = false; if configured && useCamera { cameraQueue.async { [weak self] in self?.capture.startRunning() } } }
    func shutdown() { closed = true; pauseCamera(); UIApplication.shared.isIdleTimerDisabled = false }
    func show(_ title: String, detail: String, success: Bool?) {
        titleLabel.text = title; detailLabel.text = detail
        titleLabel.textColor = success == false ? UIColor(red: 0.55, green: 0.22, blue: 0.21, alpha: 1) : UIColor(red: 0.13, green: 0.40, blue: 0.37, alpha: 1)
    }
}
