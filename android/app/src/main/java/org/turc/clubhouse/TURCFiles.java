package org.turc.clubhouse;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import androidx.core.content.FileProvider;
import com.getcapacitor.PluginCall;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.UUID;

final class TURCFiles {
    private TURCFiles() {}

    static void share(Activity activity, PluginCall call, String name, String mime, byte[] contents) {
        try {
            File cache = new File(activity.getCacheDir(), "turc-shares");
            removeStaleShares(cache);
            File folder = new File(cache, UUID.randomUUID().toString());
            if (!folder.mkdirs()) throw new IOException("Share directory could not be created");
            File file = new File(folder, name);
            try (FileOutputStream stream = new FileOutputStream(file)) {
                stream.write(contents);
            }
            Uri attachment = FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
            Intent send = new Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, attachment)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            send.setClipData(ClipData.newRawUri(name, attachment));
            activity.runOnUiThread(() -> {
                try {
                    activity.startActivity(Intent.createChooser(send, null));
                    call.resolve();
                } catch (RuntimeException e) { call.reject("The file could not be shared"); }
            });
        } catch (IOException | IllegalArgumentException e) { call.reject("The file could not be prepared"); }
    }

    private static void removeStaleShares(File root) {
        File[] folders = root.listFiles();
        if (folders == null) return;
        long cutoff = System.currentTimeMillis() - 86_400_000L;
        for (File folder : folders) {
            if (!folder.isDirectory() || folder.lastModified() >= cutoff) continue;
            File[] attachments = folder.listFiles();
            if (attachments == null) continue;
            for (File attachment : attachments) {
                if (attachment.isFile()) attachment.delete();
            }
            folder.delete();
        }
    }
}
