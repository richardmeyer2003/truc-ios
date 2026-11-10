# School-year progress and concise scanner feedback

Version 0.4.0 uses the website's existing `turc_school_progress` RPC to attach effective school-year totals to authorized roster rows. Mileage and distance to the next milestone appear beside each name, with a progress bar between the previous and next milestones. Reopening the Runners tab refreshes totals; the existing quiet refresh also includes progress changes and retains loaded data on a failed request.

The milestone helper is copied from the connected website's `dist/progress.js`: 5, 10, 13.1 (Half marathon), 25, 26.2 (Marathon), and 50 miles. Integer millimeters determine threshold crossings. A positive remainder displays at least 0.01 miles, avoiding a premature zero before a target is reached. After 50 miles the interface says “All milestones reached.” Missing totals display as unavailable.

Successful QR and NFC feedback share one formatter and contain only the runner's name, today's mileage, and miles remaining to the next school-year milestone. Example: `Maya Example` / `Today 3.00 mi · 2.00 mi to next milestone`. Lap numbers, yearly totals, and lifetime totals are removed from this feedback. Server rejection and connection messages remain explicit so an unconfirmed lap cannot look accepted.

No hosted schema changes were made. The already-applied website progress/corrections migration is included in the backend snapshot for reproducibility. Accounts, roster permissions, server-side scans, shared cooldown, UID assignment, and read-only NFC hardware operations use their existing paths. Retry feedback still reflects the original server receipt.

Validation: 22 Node checks passed, including quiet progress refresh and all milestone boundaries; browser QA at 440px verified roster layout, no horizontal overflow, scanner feedback through the native bridge mock, and existing badge assignment/printing controls. Native project checks passed. Native hardware and the system NFC sheet require the installed build on the owner's phone.
