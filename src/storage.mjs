// Supabase accepts async storage. A native failure must never fall back to web storage.
export function keychainStorage(plugin) {
  return {
    async getItem(key) { return (await plugin.getItem({ key })).value ?? null; },
    async setItem(key, value) { await plugin.setItem({ key, value }); },
    async removeItem(key) { await plugin.removeItem({ key }); }
  };
}
