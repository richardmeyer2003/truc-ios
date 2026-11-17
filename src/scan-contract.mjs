import '../web/progress.js';

export const credentialPattern = /^turc:v1:[a-f0-9]{64}$/;
export const uidPattern = /^[A-F0-9]{14}$/;
export const scannerAppearance = () => globalThis.TurcAppearance?.theme === 'black-gold' ? { theme: 'black-gold' } : {};
export function scanPayload(event, school, device) {
  const value=event.source==='nfc'?String(event.value).toUpperCase():event.value;
  if (!(event.source==='qr'?credentialPattern.test(value):event.source==='nfc'&&uidPattern.test(value))
    || !/^[a-f0-9-]{36}$/i.test(event.eventID) || !Number.isFinite(Date.parse(event.observedAt))) throw Error('Invalid TURC scan');
  return {p_school:school,p_token:value,p_event:event.eventID,p_device:device,p_source:event.source,p_observed:event.observedAt};
}
export const miles = mm => (Number(mm || 0)/1609344).toFixed(2);
export function scanFeedback(result) {
  if (result.accepted) {
    const progress=globalThis.TurcProgress;
    const total=result.totals?.year_mm;
    const milestone=total!=null&&Number.isFinite(Number(total)) ? progress.milestone(total) : null;
    const next=milestone ? (milestone.next ? `${progress.remaining(milestone.remaining)} mi to next milestone` : 'All milestones reached') : 'Next milestone unavailable';
    return {accepted:true,title:'Lap counted',student:result.name,detail:`Today ${miles(result.totals?.today_mm)} mi · ${next}`};
  }
  const reasons = {cooldown:'Too soon',unknown_or_replaced_badge:'Unknown or replaced badge',inactive_runner:'Student is not actively enrolled',course_not_configured:'Course needs setup',no_active_year:'No active school year',clock_or_connection:'Check the clock and connection'};
  if (result.reason==='cooldown' && Number.isFinite(result.remaining_seconds)) return {accepted:false,title:'Too soon',detail:`${result.remaining_seconds}s remaining. No lap added.`};
  return {accepted:false,title:reasons[result.reason] || 'Lap was not recorded',detail:'No lap added.'};
}
