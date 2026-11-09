import Foundation
import CoreGraphics
import CoreText
import CoreImage

enum TURCBadgePDF {
    static let pageSize = CGSize(width: 612, height: 792)
    static let badgeSize = CGSize(width: 2.52 * 72, height: 3.54 * 72)
    static func make(_ fields: [String: String]) throws -> Data {
        guard let token = fields["token"], token.range(of: "^turc:v1:[a-f0-9]{64}$", options: .regularExpression) != nil,
              let name = fields["student_name"], !name.isEmpty,
              fields.values.allSatisfy({ $0.count <= 400 }) else {
            throw NSError(domain: "TURCBadge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assigned runner information is required."])
        }
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw NSError(domain: "TURCBadge", code: 2)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
        let green = CGColor(red: 0.14, green: 0.42, blue: 0.38, alpha: 1)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: pageSize.height-y-h, width: w, height: h) }
        func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, bold: Bool = false, color: CGColor? = nil) {
            var pointSize = size
            var attributed = NSAttributedString(string: "")
            while true {
                let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, pointSize, nil)
                attributed = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color ?? CGColor(gray: 0.12, alpha: 1)])
                let setter = CTFramesetterCreateWithAttributedString(attributed)
                let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0,length: 0), nil, CGSize(width: width,height: 1000), nil)
                if needed.height <= height || pointSize <= 7 { break }; pointSize -= 0.5
            }
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0,length: 0), CGPath(rect: rect(x,y,width,height), transform: nil), nil)
            context.saveGState(); context.textMatrix = .identity; CTFrameDraw(frame, context); context.restoreGState()
        }
        text("TURC runner badge", x: 48,y: 38,width: 516,height: 28,size: 20,bold: true,color: green)
        text("Print at 100% / Actual Size on US Letter. Cut along the corner guides.\nFinished insert: 2.52 × 3.54 inches. Place the assigned sticker on the sleeve.", x: 48,y: 73,width: 516,height: 42,size: 11)
        let x = (pageSize.width-badgeSize.width)/2, y = (pageSize.height-badgeSize.height)/2
        context.setStrokeColor(CGColor(gray: 0.7,alpha: 1)); context.setLineWidth(0.5); context.stroke(rect(x,y,badgeSize.width,badgeSize.height))
        context.setFillColor(green); context.fill(rect(x,y,badgeSize.width,4))
        text("TURC", x:x+14,y:y+10,width:153,height:14,size:11,bold:true,color:green)
        text(fields["school_name"] ?? "",x:x+14,y:y+27,width:153,height:22,size:9)
        text(name,x:x+14,y:y+51,width:153,height:38,size:17,bold:true,color:green)
        let classroom = [fields["grade"].flatMap { $0.isEmpty ? nil : "Grade " + $0 }, fields["classroom"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        text(classroom,x:x+14,y:y+93,width:153,height:22,size:9)
        text("ID " + (fields["student_number"] ?? ""),x:x+14,y:y+117,width:153,height:12,size:9)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw NSError(domain:"TURCBadge",code:3) }
        filter.setValue(Data(token.utf8),forKey:"inputMessage"); filter.setValue("M",forKey:"inputCorrectionLevel")
        guard let code = filter.outputImage else { throw NSError(domain:"TURCBadge",code:4) }
        let qrX = x+(badgeSize.width-106)/2
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(rect(qrX,y+132,106,106))
        // Emit vector modules so the printed QR remains sharp at any printer resolution.
        let width=Int(code.extent.width),height=Int(code.extent.height)
        var pixels=[UInt8](repeating:0,count:width*height*4)
        pixels.withUnsafeMutableBytes { buffer in
            CIContext().render(code,toBitmap:buffer.baseAddress!,rowBytes:width*4,bounds:code.extent,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        }
        let module=82/CGFloat(width),area=rect(qrX+12,y+144,82,82)
        context.setFillColor(CGColor(gray:0,alpha:1))
        for row in 0..<height { for column in 0..<width where pixels[(row*width+column)*4]<128 {
            context.fill(CGRect(x:area.minX+CGFloat(column)*module,y:area.maxY-CGFloat(row+1)*module,width:module,height:module))
        } }
        text("EVERY RUNNER BELONGS",x:x+27,y:y+242,width:145,height:10,size:7,color:green)
        context.setStrokeColor(CGColor(gray:0.4,alpha:1));context.setLineWidth(0.5)
        for corner in [(x,y),(x+badgeSize.width,y),(x,y+badgeSize.height),(x+badgeSize.width,y+badgeSize.height)] {
            let dx:CGFloat = corner.0 == x ? -1 : 1, dy:CGFloat = corner.1 == y ? -1 : 1
            context.move(to:CGPoint(x:corner.0+dx*4,y:pageSize.height-corner.1));context.addLine(to:CGPoint(x:corner.0+dx*14,y:pageSize.height-corner.1))
            context.move(to:CGPoint(x:corner.0,y:pageSize.height-corner.1-dy*4));context.addLine(to:CGPoint(x:corner.0,y:pageSize.height-corner.1-dy*14))
        }
        context.strokePath()
        context.endPDFPage();context.closePDF()
        return data as Data
    }
}
