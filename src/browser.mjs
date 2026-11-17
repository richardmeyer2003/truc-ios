import { createScanning } from './scanning.mjs';
import { createBrowserScanner } from './browser-scanner.mjs';
import { qrImage, shareBadgePDF } from './browser-badge.mjs';

window.TURC_PLATFORM = { webApp: true };
window.TURC_SCANNER = createScanning({ ...createBrowserScanner(), qrImage, shareBadgePDF }, true, { web: true });
