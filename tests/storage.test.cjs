const test = require('node:test');
const assert = require('node:assert/strict');

test('native session storage reads, replaces, and removes values through the bridge', async () => {
  const { keychainStorage } = await import('../src/storage.mjs');
  const values = new Map();
  const storage = keychainStorage({
    getItem: async ({key}) => ({value:values.get(key) ?? null}),
    setItem: async ({key,value}) => { values.set(key,value); },
    removeItem: async ({key}) => { values.delete(key); }
  });
  assert.equal(await storage.getItem('turc-auth-v1'),null);
  await storage.setItem('turc-auth-v1','fictional-session');
  assert.equal(await storage.getItem('turc-auth-v1'),'fictional-session');
  await storage.setItem('turc-auth-v1','refreshed-session');
  assert.equal(await storage.getItem('turc-auth-v1'),'refreshed-session');
  await storage.removeItem('turc-auth-v1');
  assert.equal(await storage.getItem('turc-auth-v1'),null);
});

test('Keychain failures propagate instead of silently persisting tokens elsewhere', async () => {
  const { keychainStorage } = await import('../src/storage.mjs');
  const fail = async () => { throw new Error('Keychain unavailable'); };
  const storage = keychainStorage({getItem:fail,setItem:fail,removeItem:fail});
  await assert.rejects(storage.getItem('turc-auth-v1'),/Keychain/);
  await assert.rejects(storage.setItem('turc-auth-v1','session'),/Keychain/);
  await assert.rejects(storage.removeItem('turc-auth-v1'),/Keychain/);
});
