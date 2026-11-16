package org.turc.clubhouse;

final class TURCScanRules {
    private static final String BIB = "wt1:[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}";

    private TURCScanRules() {}

    static boolean accepts(boolean walkathon, String source, String value) {
        if (value == null || value.length() > 95) return false;
        if (walkathon) return "qr".equals(source) && value.matches(BIB);
        if ("nfc".equals(source)) return value.matches("[A-F0-9]{14}");
        return "qr".equals(source) && value.matches(TURCBadge.TOKEN);
    }

    static boolean isNtag215(byte[] response) {
        return response != null && response.length == 8 && response[1] == 0x04 && response[2] == 0x04 && response[6] == 0x11;
    }
}
