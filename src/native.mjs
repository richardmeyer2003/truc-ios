import { Capacitor, SystemBars, SystemBarsStyle, registerPlugin } from '@capacitor/core';
import { App } from '@capacitor/app';
import { keychainStorage } from './storage.mjs';
import { createScanning } from './scanning.mjs';

const isNative = Capacitor.isNativePlatform();
const native = registerPlugin('TURCNative');
window.TURC_SCANNER = createScanning(registerPlugin('TURCScanner'),isNative);
window.TURC_PLATFORM = {
  isNative,
  applyTheme(theme) {
    if(isNative)void SystemBars.setStyle({style:theme==='black-gold'?SystemBarsStyle.Dark:SystemBarsStyle.Light}).catch(()=>{});
  },
  async ready() {
    if (isNative && !Capacitor.isPluginAvailable('TURCNative')) {
      throw new Error('Secure sign-in is unavailable in this build. Please install a new TURC build.');
    }
  },
  authStorage: isNative ? keychainStorage(native) : undefined,
  async shareCSV(name, text) { await native.shareCSV({ name, text }); },
  async attachClient(client) {
    if (!isNative) return;
    if (Capacitor.getPlatform()==='android') {
      await App.addListener('backButton',()=>{
        if (window.dispatchEvent(new Event('turc:android-back',{cancelable:true}))) void App.minimizeApp();
      });
    }
    const update = ({ isActive }) => {
      if (isActive) {
        client.auth.startAutoRefresh();
        window.dispatchEvent(new Event('turc:resume'));
      } else client.auth.stopAutoRefresh();
    };
    await App.addListener('appStateChange', update);
    update(await App.getState());
  }
};
document.addEventListener('click', event => {
  const link = event.target.closest('a[data-website]');
  if (!isNative || !link) return;
  event.preventDefault();
  native.openWebsite({route:link.dataset.website||'home',school:link.dataset.school,event:link.dataset.event}).catch(() => {
    const status = document.getElementById('club-status');
    status.textContent = 'The website could not open. Please try again.'; status.hidden = false;
  });
});
