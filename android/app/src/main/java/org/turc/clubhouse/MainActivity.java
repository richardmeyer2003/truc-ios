package org.turc.clubhouse;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle state) {
        registerPlugin(TURCNativePlugin.class);
        registerPlugin(TURCScannerPlugin.class);
        super.onCreate(state);
    }
}
