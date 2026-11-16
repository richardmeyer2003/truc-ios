package org.turc.clubhouse;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class TURCScanRulesTest {
    private static final String BADGE = "turc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static final String BIB = "wt1:00000000-0000-4000-8000-000000000001";

    @Test public void runClubAcceptsItsBadgesAndFactoryUids() {
        assertTrue(TURCScanRules.accepts(false, "qr", BADGE));
        assertTrue(TURCScanRules.accepts(false, "nfc", "04112233445566"));
        assertFalse(TURCScanRules.accepts(false, "qr", BIB));
        assertFalse(TURCScanRules.accepts(false, "unknown", BADGE));
    }

    @Test public void walkathonAcceptsOnlyBibQrCodes() {
        assertTrue(TURCScanRules.accepts(true, "qr", BIB));
        assertFalse(TURCScanRules.accepts(true, "qr", BADGE));
        assertFalse(TURCScanRules.accepts(true, "nfc", "04112233445566"));
        assertFalse(TURCScanRules.accepts(true, "qr", null));
    }

    @Test public void rejectsOtherTagVersions() {
        byte[] ntag215 = {0, 4, 4, 2, 1, 0, 0x11, 3};
        assertTrue(TURCScanRules.isNtag215(ntag215));
        ntag215[6] = 0x13;
        assertFalse(TURCScanRules.isNtag215(ntag215));
        assertFalse(TURCScanRules.isNtag215(new byte[]{0, 4, 4}));
    }
}
