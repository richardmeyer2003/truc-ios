package org.turc.clubhouse;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

@CapacitorPlugin(name = "TURCNative")
public class TURCNativePlugin extends Plugin {
    private static final String KEY_ALIAS = "turc.session.v1";
    private static final int IV_BYTES = 12;

    private boolean allowedKey(String key) {
        return "turc-auth-v1".equals(key) || "turc-auth-v1-code-verifier".equals(key) || "turc-auth-v1-user".equals(key);
    }

    private SharedPreferences storage() {
        return getContext().getSharedPreferences("turc_secure_sessions", Context.MODE_PRIVATE);
    }

    private synchronized SecretKey sessionKey(boolean create) throws GeneralSecurityException, IOException {
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        SecretKey key = (SecretKey) keys.getKey(KEY_ALIAS, null);
        if (key != null) return key;
        if (!create) throw new GeneralSecurityException("Session key is missing");
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return generator.generateKey();
    }

    @PluginMethod
    public void getItem(PluginCall call) {
        String name = call.getString("key");
        if (!allowedKey(name)) { call.reject("Unsupported session key"); return; }
        try {
            JSObject result = new JSObject();
            String record = storage().getString(name, null);
            if (record == null) {
                result.put("value", JSONObject.NULL);
            } else {
                byte[] encrypted = Base64.decode(record, Base64.NO_WRAP);
                ByteBuffer buffer = ByteBuffer.wrap(encrypted);
                byte[] iv = new byte[IV_BYTES];
                buffer.get(iv);
                byte[] ciphertext = new byte[buffer.remaining()];
                buffer.get(ciphertext);
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE, sessionKey(false), new GCMParameterSpec(128, iv));
                cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
                result.put("value", new String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8));
            }
            call.resolve(result);
        } catch (Exception e) { call.reject("Secure session could not be read", "SECURE_STORAGE_READ"); }
    }

    @PluginMethod
    public void setItem(PluginCall call) {
        String name = call.getString("key");
        String value = call.getString("value");
        if (!allowedKey(name) || value == null) { call.reject("A supported session key and value are required"); return; }
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, sessionKey(true));
            cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
            byte[] ciphertext = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
            byte[] iv = cipher.getIV();
            if (iv.length != IV_BYTES) throw new GeneralSecurityException("Unexpected IV length");
            byte[] record = ByteBuffer.allocate(iv.length + ciphertext.length).put(iv).put(ciphertext).array();
            if (!storage().edit().putString(name, Base64.encodeToString(record, Base64.NO_WRAP)).commit()) {
                throw new IOException("Could not persist the secure session");
            }
            call.resolve();
        } catch (Exception e) { call.reject("Secure session could not be saved", "SECURE_STORAGE_WRITE"); }
    }

    @PluginMethod
    public void removeItem(PluginCall call) {
        String name = call.getString("key");
        if (!allowedKey(name)) { call.reject("Unsupported session key"); return; }
        if (storage().edit().remove(name).commit()) call.resolve();
        else call.reject("Secure session could not be removed", "SECURE_STORAGE_REMOVE");
    }

    @PluginMethod
    public void openWebsite(PluginCall call) {
        Uri.Builder destination = new Uri.Builder().scheme("https")
                .authority("turc-school-run-club.richer2003.chatgpt.site").path("/club");
        String school = canonicalId(call.getString("school"));
        switch (call.getString("route", "home")) {
            case "home": break;
            case "schools": destination.fragment("schools"); break;
            case "accounts": destination.fragment("accounts"); break;
            case "walkathon":
                destination.path("/walkathon");
                if (school != null) destination.appendQueryParameter("school", school);
                break;
            case "leaderboard":
                String event = canonicalId(call.getString("event"));
                if (event == null || school == null) { call.reject("Select a Walk-a-thon first"); return; }
                destination.path("/walkathon").appendQueryParameter("display", "1")
                        .appendQueryParameter("school", school).appendQueryParameter("event", event);
                break;
            default: call.reject("Unknown website destination"); return;
        }
        getActivity().runOnUiThread(() -> {
            try {
                getActivity().startActivity(new Intent(Intent.ACTION_VIEW, destination.build()));
                call.resolve();
            } catch (RuntimeException e) { call.reject("The website could not open"); }
        });
    }

    private String canonicalId(String value) {
        if (value == null || !value.matches("[a-fA-F0-9-]{36}")) return null;
        try { return UUID.fromString(value).toString(); }
        catch (IllegalArgumentException e) { return null; }
    }

    @PluginMethod
    public void shareCSV(PluginCall call) {
        String name = call.getString("name");
        String text = call.getString("text");
        if (text == null || !("turc-roster.csv".equals(name) || "turc-roster-example.csv".equals(name))) {
            call.reject("Invalid CSV export"); return;
        }
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        if (data.length > 10_485_760) { call.reject("CSV export is too large"); return; }
        TURCFiles.share(getActivity(), call, name, "text/csv", data);
    }
}
