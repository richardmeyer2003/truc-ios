package org.turc.clubhouse;

import android.Manifest;
import android.app.Dialog;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.nfc.NfcAdapter;
import android.nfc.NfcManager;
import android.nfc.Tag;
import android.nfc.tech.NfcA;
import android.os.Build;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.google.zxing.BarcodeFormat;
import com.journeyapps.barcodescanner.DecoratedBarcodeView;
import com.journeyapps.barcodescanner.DefaultDecoderFactory;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

@CapacitorPlugin(name = "TURCScanner", permissions = @Permission(alias = "camera", strings = {Manifest.permission.CAMERA}))
public class TURCScannerPlugin extends Plugin {
    private static final int DARK = Color.rgb(23, 53, 51);
    private static final int GREEN = Color.rgb(20, 88, 62);
    private static final int AMBER = Color.rgb(111, 58, 11);
    private static final int CHARCOAL = 0xff19191b;
    private static final int GOLD = 0xffd8b875;
    private static final int IVORY = 0xfff4efe6;
    private boolean blackGold;
    private final Map<String, Long> recent = new HashMap<>();

    private Dialog sheet;
    private FrameLayout preview;
    private DecoratedBarcodeView camera;
    private LinearLayout feedback;
    private TextView statusTitle;
    private TextView statusDetail;
    private PluginCall cameraRequest;
    private PluginCall pairing;
    private String runId;
    private boolean walkathon;
    private boolean awaitingResult;
    private boolean usingNfc;
    private volatile int readerGeneration;

    private NfcAdapter nfc() {
        NfcManager manager = (NfcManager) getContext().getSystemService(Context.NFC_SERVICE);
        return manager == null ? null : manager.getDefaultAdapter();
    }

    @PluginMethod
    public void capabilities(PluginCall call) {
        JSObject result = new JSObject();
        result.put("camera", getContext().getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY));
        result.put("nfc", nfc() != null);
        call.resolve(result);
    }

    @PluginMethod
    public void open(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            String mode = call.getString("mode", "qr");
            if (sheet != null || cameraRequest != null) { call.reject("Close the open scanner first"); return; }
            if (!"qr".equals(mode) && !"nfc".equals(mode) && !"walkathon".equals(mode)) {
                call.reject("Unknown scanning mode"); return;
            }
            if ("nfc".equals(mode)) {
                if (!nfcReady(call)) return;
                startScanner(call, mode);
            } else if (!getContext().getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
                call.reject("A camera is unavailable on this device");
            } else if (getPermissionState("camera") != PermissionState.GRANTED) {
                cameraRequest = call;
                requestPermissionForAlias("camera", call, "cameraPermission");
            } else startScanner(call, mode);
        });
    }

    @PermissionCallback
    private void cameraPermission(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            if (cameraRequest != call) return;
            cameraRequest = null;
            if (getPermissionState("camera") != PermissionState.GRANTED) {
                call.reject("Allow Camera for TURC to scan QR codes"); return;
            }
            startScanner(call, call.getString("mode", "qr"));
        });
    }

    private void startScanner(PluginCall call, String mode) {
        blackGold = "black-gold".equals(call.getString("theme"));
        runId = call.getString("runID", UUID.randomUUID().toString());
        walkathon = "walkathon".equals(mode);
        showSheet((walkathon ? "Walk-a-thon" : "Run Club") + "\n" + call.getString("school", "Your school"));
        if ("nfc".equals(mode)) startReader();
        else startCamera();
        JSObject result = new JSObject();
        result.put("runID", runId);
        call.resolve(result);
    }

    @PluginMethod
    public void readTagUID(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            if (sheet != null || cameraRequest != null) { call.reject("Close the scanner before assigning a sticker"); return; }
            if (!nfcReady(call)) return;
            pairing = call;
            blackGold = "black-gold".equals(call.getString("theme"));
            showSheet("Assign NFC sticker");
            startReader();
        });
    }

    private boolean nfcReady(PluginCall call) {
        NfcAdapter adapter = nfc();
        if (adapter == null) { call.reject("This device does not support NFC"); return false; }
        if (!adapter.isEnabled()) { call.reject("Turn on NFC in Android Settings"); return false; }
        return true;
    }

    private void showSheet(String title) {
        Dialog dialog = new Dialog(getActivity(), android.R.style.Theme_Material_NoActionBar);
        sheet = dialog;
        LinearLayout layout = column();
        layout.setBackgroundColor(blackGold ? 0xff0b0b0c : DARK);
        layout.setPadding(dp(14), dp(14), dp(14), dp(12));

        LinearLayout header = new LinearLayout(getActivity());
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView heading = label(title, 19, blackGold ? GOLD : Color.WHITE, true);
        header.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        header.addView(button("Done", this::finish));
        layout.addView(header);

        preview = new FrameLayout(getActivity());
        layout.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1));
        feedback = column();
        feedback.setPadding(dp(16), dp(12), dp(16), dp(14));
        statusTitle = label("", 24, DARK, true);
        statusTitle.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        statusDetail = label("", 16, blackGold ? IVORY : DARK, false);
        statusDetail.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        feedback.addView(statusTitle);
        feedback.addView(statusDetail);
        layout.addView(feedback, new LinearLayout.LayoutParams(-1, -2));

        if (!walkathon && pairing == null) {
            LinearLayout modes = new LinearLayout(getActivity());
            modes.addView(button("QR camera", this::startCamera), new LinearLayout.LayoutParams(0, -2, 1));
            modes.addView(button("NFC stickers", this::startReader), new LinearLayout.LayoutParams(0, -2, 1));
            layout.addView(modes, new LinearLayout.LayoutParams(-1, -2));
        }
        dialog.setContentView(layout);
        dialog.setOnDismissListener(ignored -> { if (sheet == dialog) finish(); });
        dialog.show();
        Window window = dialog.getWindow();
        if (window != null) {
            window.setLayout(-1, -1);
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
        show("Ready to scan", "Present one badge at a time.", null);
    }

    private void startCamera() {
        if (awaitingResult || sheet == null) return;
        if (getPermissionState("camera") != PermissionState.GRANTED) {
            show("Camera permission needed", "Open QR camera from the Scan screen to grant access.", false);
            return;
        }
        stopReader();
        preview.removeAllViews();
        if (camera == null) {
            camera = new DecoratedBarcodeView(getActivity());
            camera.setDecoderFactory(new DefaultDecoderFactory(Collections.singletonList(BarcodeFormat.QR_CODE)));
            camera.setStatusText("");
            camera.decodeContinuous(result -> accept(result.getText(), "qr"));
        }
        preview.addView(camera, new FrameLayout.LayoutParams(-1, -1));
        camera.resume();
        show("Ready to scan", walkathon ? "Point the camera at the event bib." : "Point the camera at the student’s QR badge.", null);
    }

    private void startReader() {
        if (awaitingResult || sheet == null || usingNfc) return;
        NfcAdapter adapter = nfc();
        if (adapter == null || !adapter.isEnabled()) {
            show("NFC unavailable", adapter == null ? "This phone does not support NFC." : "Turn on NFC in Android Settings.", false);
            return;
        }
        if (camera != null) camera.pause();
        preview.removeAllViews();
        TextView prompt = label("Hold an NTAG215 sticker to the back of this phone.", 19, blackGold ? IVORY : Color.WHITE, true);
        prompt.setGravity(Gravity.CENTER);
        prompt.setPadding(dp(16), dp(16), dp(16), dp(16));
        preview.addView(prompt, new FrameLayout.LayoutParams(-1, -1));

        int ticket = ++readerGeneration;
        AtomicBoolean reading = new AtomicBoolean();
        try {
            adapter.enableReaderMode(getActivity(), tag -> {
                if (ticket != readerGeneration || !reading.compareAndSet(false, true)) return;
                String uid = null;
                try { uid = readUid(tag); }
                catch (IOException | RuntimeException ignored) { /* Move the sticker back into range to retry. */ }
                String result = uid;
                getActivity().runOnUiThread(() -> {
                    try {
                        if (ticket != readerGeneration || sheet == null || awaitingResult) return;
                        if (result == null) {
                            show("Sticker could not be read", "Hold one NTAG215 sticker steady against the phone.", false);
                        } else if (pairing != null) {
                            PluginCall assignment = pairing;
                            pairing = null;
                            finish();
                            JSObject payload = new JSObject();
                            payload.put("uid", result);
                            payload.put("tagType", "NTAG215");
                            assignment.resolve(payload);
                        } else accept(result, "nfc");
                    } finally { reading.set(false); }
                });
            }, NfcAdapter.FLAG_READER_NFC_A | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK, null);
            usingNfc = true;
            show("Ready for NFC", "Present one NTAG215 sticker.", null);
        } catch (IllegalStateException | UnsupportedOperationException e) {
            show("NFC could not start", "Close the scanner and try again.", false);
        }
    }

    private String readUid(Tag tag) throws IOException {
        byte[] identifier = tag.getId();
        NfcA channel = NfcA.get(tag);
        if (identifier == null || identifier.length != 7 || channel == null) return null;
        try {
            channel.connect();
            // NXP GET_VERSION identifies the sticker. The reader does not write tag memory.
            byte[] version = channel.transceive(new byte[]{0x60});
            if (!TURCScanRules.isNtag215(version)) return null;
            StringBuilder uid = new StringBuilder(14);
            for (byte value : identifier) uid.append(String.format(Locale.ROOT, "%02X", value & 0xff));
            return uid.toString();
        } finally { channel.close(); }
    }

    private void stopReader() {
        readerGeneration++;
        if (usingNfc) {
            usingNfc = false;
            NfcAdapter adapter = nfc();
            if (adapter != null) {
                try { adapter.disableReaderMode(getActivity()); }
                catch (IllegalStateException | UnsupportedOperationException ignored) {}
            }
        }
    }

    private void accept(String value, String source) {
        if (runId == null || awaitingResult || value == null) return;
        if (!TURCScanRules.accepts(walkathon, source, value)) {
            show(walkathon ? "Use a Walk-a-thon bib" : "Not a TURC badge",
                    walkathon ? "Point the camera at an event bib QR code." : "Use the student’s Run Club badge or sticker.", false);
            return;
        }
        long time = SystemClock.elapsedRealtime();
        Long last = recent.put(value, time);
        if (last != null && time - last < 1500) return;
        if (recent.size() > 300) recent.values().removeIf(seen -> time - seen > 5000);

        awaitingResult = true;
        show("Checking lap…", "Wait for confirmation.", null);
        SimpleDateFormat timestamp = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT);
        timestamp.setTimeZone(TimeZone.getTimeZone("UTC"));
        JSObject event = new JSObject();
        event.put("runID", runId);
        event.put("value", value);
        event.put("source", source);
        event.put("eventID", UUID.randomUUID().toString());
        event.put("observedAt", timestamp.format(new Date()));
        notifyListeners("scan", event);
    }

    @PluginMethod
    public void feedback(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            if (runId != null && runId.equals(call.getString("runID"))) {
                awaitingResult = call.getBoolean("pending", false);
                boolean accepted = call.getBoolean("accepted", false);
                String student = call.getString("student", "");
                String detail = call.getString("detail", "");
                show(call.getString("title", ""), student.isEmpty() ? detail : student + "\n" + detail, accepted);
                int haptic = Build.VERSION.SDK_INT < 30 ? HapticFeedbackConstants.LONG_PRESS
                        : accepted ? HapticFeedbackConstants.CONFIRM : HapticFeedbackConstants.REJECT;
                feedback.performHapticFeedback(haptic);
            }
            call.resolve();
        });
    }

    private void show(String title, String detail, Boolean accepted) {
        if (feedback == null) return;
        statusTitle.setText(title);
        statusDetail.setText(detail);
        if (blackGold) {
            statusTitle.setTextColor(Boolean.FALSE.equals(accepted) ? 0xffffb5b4 : GOLD);
            feedback.setBackgroundColor(CHARCOAL);
            return;
        }
        statusTitle.setTextColor(accepted == null ? DARK : accepted ? GREEN : AMBER);
        feedback.setBackgroundColor(accepted == null ? Color.rgb(245, 250, 248)
                : accepted ? Color.rgb(223, 242, 231) : Color.rgb(255, 241, 216));
    }

    @PluginMethod
    public void close(PluginCall call) {
        getActivity().runOnUiThread(() -> { finish(); call.resolve(); });
    }

    private void finish() {
        stopReader();
        if (camera != null) { camera.pause(); camera = null; }
        Dialog old = sheet;
        sheet = null;
        if (old != null) {
            old.setOnDismissListener(null);
            old.dismiss();
        }
        feedback = null;
        statusTitle = null;
        statusDetail = null;
        preview = null;
        recent.clear();
        awaitingResult = false;
        walkathon = false;
        if (cameraRequest != null) {
            cameraRequest.reject("Scanner closed");
            cameraRequest = null;
        }
        if (pairing != null) {
            pairing.reject("Sticker scan canceled");
            pairing = null;
        }
        String id = runId;
        runId = null;
        if (id != null) {
            JSObject result = new JSObject();
            result.put("runID", id);
            notifyListeners("closed", result);
        }
    }

    @Override protected void handleOnPause() { if (sheet != null) finish(); }
    @Override protected void handleOnDestroy() { finish(); }

    @PluginMethod
    public void qrImage(PluginCall call) {
        try {
            JSObject result = new JSObject();
            result.put("dataURL", TURCBadge.image(call.getString("token")));
            call.resolve(result);
        } catch (Exception e) { call.reject("QR image could not be prepared"); }
    }

    @PluginMethod
    public void shareBadgePDF(PluginCall call) {
        Map<String, String> fields = new HashMap<>();
        for (String name : new String[]{"token", "student_name", "school_name", "grade", "classroom", "student_number"}) {
            fields.put(name, call.getString(name, ""));
        }
        try {
            TURCFiles.share(getActivity(), call, "TURC-student-badge.pdf", "application/pdf", TURCBadge.pdf(fields));
        } catch (Exception e) { call.reject("The badge PDF could not be prepared"); }
    }

    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(getActivity());
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }

    private TextView label(String text, int size, int color, boolean bold) {
        TextView view = new TextView(getActivity());
        view.setText(text); view.setTextSize(size); view.setTextColor(color);
        if (bold) view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return view;
    }

    private Button button(String title, Runnable action) {
        Button view = new Button(getActivity());
        view.setText(title); view.setAllCaps(false);
        if (blackGold) {
            boolean primary = "QR camera".equals(title);
            view.setTextColor(primary ? Color.BLACK : GOLD);
            view.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary ? GOLD : CHARCOAL));
        }
        view.setMinHeight(dp(48)); view.setOnClickListener(ignored -> action.run());
        return view;
    }

    private int dp(int value) { return Math.round(value * getContext().getResources().getDisplayMetrics().density); }
}
