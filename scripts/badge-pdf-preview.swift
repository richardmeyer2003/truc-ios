import Foundation
import CoreGraphics
import ImageIO
import Vision

@main struct BadgePreview {
    static func main() throws {
        let token="turc:v1:"+String(repeating:"a",count:64)
        let data=try TURCBadgePDF.make(["token":token,"student_name":"Maya Example","student_number":"000123","school_name":"Oakwood Elementary","grade":"3","classroom":"Ms. Parker"])
        let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:directory.appendingPathComponent("TURC-fictional-badge-preview.pdf"))
        guard let provider=CGDataProvider(data:data as CFData),let document=CGPDFDocument(provider),let page=document.page(at:1),document.numberOfPages==1 else {fatalError("Invalid badge PDF")}
        let box=page.getBoxRect(.mediaBox);precondition(box.width==612 && box.height==792)
        let width=1836,height=2376
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {fatalError("No bitmap context")}
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height));context.scaleBy(x:3,y:3);context.drawPDFPage(page)
        guard let image=context.makeImage() else {fatalError("PDF rendering failed")}
        let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        precondition(request.results?.contains(where:{$0.payloadStringValue==token})==true,"Printed QR failed to decode")
        func save(_ image:CGImage,_ filename:String){guard let destination=CGImageDestinationCreateWithURL(directory.appendingPathComponent(filename) as CFURL,"public.png" as CFString,1,nil) else {fatalError("PNG output failed")};CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))}
        save(image,"TURC-fictional-badge-preview.png")
        let badge=TURCBadgePDF.badgeSize
        if let detail=image.cropping(to:CGRect(x:(612-badge.width)*1.5-30,y:(792-badge.height)*1.5-30,width:badge.width*3+60,height:badge.height*3+60)){save(detail,"TURC-fictional-badge-detail.png")}
        print("Badge PDF verified: Letter page, 2.52 × 3.54 inch layout, rendered PNG, and decoded QR.")
    }
}
