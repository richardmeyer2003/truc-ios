package org.turc.clubhouse;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.pdf.PdfDocument;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.util.Base64;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.WriterException;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Collections;
import java.util.Map;

final class TURCBadge {
    static final String TOKEN = "turc:v1:[a-f0-9]{64}";
    private static final int GREEN = Color.rgb(36, 101, 89);
    private static final int INK = Color.rgb(36, 55, 50);

    private TURCBadge() {}

    private static BitMatrix qr(String token, int size) throws WriterException {
        if (token == null || !token.matches(TOKEN)) throw new IllegalArgumentException("Invalid badge QR");
        return new QRCodeWriter().encode(token, BarcodeFormat.QR_CODE, size, size,
                Collections.singletonMap(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M));
    }

    static String image(String token) throws WriterException {
        BitMatrix matrix = qr(token, 320);
        Bitmap bitmap = Bitmap.createBitmap(matrix.getWidth(), matrix.getHeight(), Bitmap.Config.ARGB_8888);
        try {
            int[] row = new int[matrix.getWidth()];
            for (int y = 0; y < matrix.getHeight(); y++) {
                for (int x = 0; x < row.length; x++) row[x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
                bitmap.setPixels(row, 0, row.length, 0, y, row.length, 1);
            }
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, data);
            return "data:image/png;base64," + Base64.encodeToString(data.toByteArray(), Base64.NO_WRAP);
        } finally { bitmap.recycle(); }
    }

    static byte[] pdf(Map<String, String> fields) throws WriterException, IOException {
        BitMatrix matrix = qr(fields.get("token"), 1);
        String student = fields.get("student_name");
        if (student == null || student.trim().isEmpty()) throw new IllegalArgumentException("Student name required");
        for (String value : fields.values()) {
            if (value != null && value.length() > 400) throw new IllegalArgumentException("Badge field is too long");
        }
        PdfDocument pdf = new PdfDocument();
        try {
            PdfDocument.Page page = pdf.startPage(new PdfDocument.PageInfo.Builder(612, 792, 1).create());
            Canvas canvas = page.getCanvas();
            canvas.drawColor(Color.WHITE);
            text(canvas, "TURC runner badge", 48, 38, 516, 30, 22, true, GREEN);
            text(canvas, "Print at 100% / Actual Size on US Letter. Cut along the corner guides.\nFinished insert: 2.52 × 3.54 inches. Place the assigned sticker on the sleeve.",
                    48, 73, 516, 45, 12, false, INK);
            float width = 2.52f * 72, height = 3.54f * 72, x = (612 - width) / 2, y = (792 - height) / 2;
            Paint paint = new Paint();
            paint.setColor(GREEN); canvas.drawRect(x, y, x + width, y + 4, paint);
            paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(.5f); paint.setColor(Color.GRAY);
            canvas.drawRect(x, y, x + width, y + height, paint);
            canvas.drawLine(x - 14, y, x - 4, y, paint);
            canvas.drawLine(x, y - 14, x, y - 4, paint);
            canvas.drawLine(x + width + 4, y, x + width + 14, y, paint);
            canvas.drawLine(x + width, y - 14, x + width, y - 4, paint);
            canvas.drawLine(x - 14, y + height, x - 4, y + height, paint);
            canvas.drawLine(x, y + height + 4, x, y + height + 14, paint);
            canvas.drawLine(x + width + 4, y + height, x + width + 14, y + height, paint);
            canvas.drawLine(x + width, y + height + 4, x + width, y + height + 14, paint);

            text(canvas, "TURC", x + 14, y + 11, 154, 14, 11, true, GREEN);
            text(canvas, fields.get("school_name"), x + 14, y + 28, 154, 23, 9, false, INK);
            text(canvas, student, x + 14, y + 51, 154, 42, 18, true, GREEN);
            String grade = fields.get("grade"), classroom = fields.get("classroom");
            String placement = grade == null || grade.isEmpty() ? "" : "Grade " + grade;
            if (classroom != null && !classroom.isEmpty()) placement += (placement.isEmpty() ? "" : " · ") + classroom;
            text(canvas, placement, x + 14, y + 96, 154, 24, 10, false, INK);
            text(canvas, "ID " + fields.get("student_number"), x + 14, y + 122, 154, 14, 9, false, INK);

            paint.setStyle(Paint.Style.FILL); paint.setColor(Color.BLACK);
            float extent = 97, module = extent / matrix.getWidth(), left = x + (width - extent) / 2, top = y + 144;
            for (int row = 0; row < matrix.getHeight(); row++) {
                for (int col = 0; col < matrix.getWidth(); col++) {
                    if (matrix.get(col, row)) canvas.drawRect(left + col * module, top + row * module,
                            left + (col + 1) * module, top + (row + 1) * module, paint);
                }
            }
            pdf.finishPage(page);
            ByteArrayOutputStream contents = new ByteArrayOutputStream();
            pdf.writeTo(contents);
            return contents.toByteArray();
        } finally { pdf.close(); }
    }

    private static void text(Canvas canvas, String text, float x, float y, int width, int height,
                             int size, boolean bold, int color) {
        if (text == null || text.isEmpty()) return;
        TextPaint paint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        paint.setColor(color);
        paint.setTypeface(Typeface.create("sans-serif", bold ? Typeface.BOLD : Typeface.NORMAL));
        StaticLayout layout;
        do {
            paint.setTextSize(size--);
            layout = StaticLayout.Builder.obtain(text, 0, text.length(), paint, width)
                    .setAlignment(Layout.Alignment.ALIGN_NORMAL).setIncludePad(false).build();
        } while (layout.getHeight() > height && size >= 7);
        canvas.save();
        canvas.translate(x, y);
        canvas.clipRect(0, 0, width, height);
        layout.draw(canvas);
        canvas.restore();
    }
}
