# Shared hosted backend

Current badge workflow is read-only UID assignment, added by `20261109224925_turc_uid_badge_assignment.sql`. QR credentials are issued only after an Admin assigns an NTAG215 UID to a student. The former QR-first/NDEF-confirmation endpoints are retired. See `docs/uid-badge-checkpoint.md` in the repository root.

These are copies of the canonical applied migrations from `D:\Run Club\backend\supabase\migrations` for reproducibility. They are **already applied** to project `gafdrcjkcwazfeebmhgd`. No database password or service-role credential belongs in this repository or the app.

`20261109221649_turc_native_scanning.sql` adds private course, badge, session, and attempt storage; the RLS-protected lap table; and authenticated RPCs. Public functions are invoker wrappers around private, live-authorized implementations. Credentials never authorize access to student information by themselves. Staff cannot issue badges or configure courses. Parents cannot submit scans; they can read only linked-child totals.

Badge/course changes and accepted laps create audit entries containing changed field names. No raw scanned credential is stored in attempt logs. Retry keys are scoped to the operator and bound to the original event payload. Student-row locking serializes accepted lap/cooldown checks across devices and badge replacement.

Private operational tables intentionally have RLS without policies and no browser table grants. Supabase's informational no-policy notices are expected for these deny-by-default tables. [Advisor explanation](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy). Existing leaked-password protection remains unavailable on the selected Free plan; no paid service was enabled.

Hosted verification passed 26 new scanning checks plus the existing 36 foundation and 21 import checks. All use isolated fictional fixtures and end with ROLLBACK. No test login credentials or persistent runners were created.
# Progress snapshot

`20261110032634_turc_progress_corrections.sql` was already deployed by the connected website. Version 0.4.0 consumes its authorized school-progress RPC and effective scan totals; do not reapply the migration to the existing hosted project.
