export const credentialPattern = /^turc:v1:[a-f0-9]{64}$/;
export const uidPattern = /^[A-F0-9]{14}$/;
export function scanPayload(event, school, device) {
  const value=event.source==='nfc'?String(event.value).toUpperCase():event.value;
  if (!(event.source==='qr'?credentialPattern.test(value):event.source==='nfc'&&uidPattern.test(value))
    || !/^[a-f0-9-]{36}$/i.test(event.eventID) || !Number.isFinite(Date.parse(event.observedAt))) throw Error('Invalid TURC scan');
  return {p_school:school,p_token:value,p_event:event.eventID,p_device:device,p_source:event.source,p_observed:event.observedAt};
}
export const miles = mm => (Number(mm || 0)/1609344).toFixed(2);
export function scanFeedback(result) {
  if (result.accepted) return {accepted:true,title:`${result.name} · Lap ${result.totals.today_laps}`,
    detail:`Today ${miles(result.totals.today_mm)} mi · Year ${miles(result.totals.year_mm)} mi · Lifetime ${miles(result.totals.lifetime_mm)} mi`};
  const reasons = {cooldown:'Too soon for another lap',unknown_or_replaced_badge:'Unknown or replaced badge',inactive_runner:'Runner is not actively enrolled',course_not_configured:'Ask an Admin to configure the course',no_active_year:'No active school year for today',clock_or_connection:'Check your clock and connection; scan again'};
  return {accepted:false,title:reasons[result.reason] || 'Lap was not recorded',detail:'No lap added.'};
}
