export function scanAccess(context) {
  if (!context?.user || !context.school || context.school.active === false) return {run:false,walk:false,leaderboard:false};
  if (context.role === 'admin') return {run:true,walk:true,leaderboard:true};
  const staff = context.role === 'staff' && context.memberships?.find(m =>
    m.user_id === context.user.id && m.school_id === context.school.id && m.role === 'staff' && m.active);
  return {run:staff?.can_scan_run_club === true,walk:staff?.can_scan_walkathon === true,leaderboard:staff?.can_view_walkathon === true};
}
