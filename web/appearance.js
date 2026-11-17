(function () {
  'use strict';

  const options = [
    { id: 'liquid-glass', label: 'Liquid Glass', color: '#e7f0f3' },
    { id: 'black-gold', label: 'Black & Gold', color: '#0b0b0c' }
  ];
  let current = options[0];

  function apply(user) {
    current = options.find(option => option.id === user?.user_metadata?.turc_theme) || options[0];
    const root = document.documentElement;
    if (root.dataset.turcTheme !== current.id) {
      root.dataset.turcTheme = current.id;
      document.querySelector('meta[name="theme-color"]')?.setAttribute('content', current.color);
      window.TURC_PLATFORM?.applyTheme?.(current.id);
    }
    for (const button of document.querySelectorAll('[data-theme-choice]')) {
      button.setAttribute('aria-pressed', String(button.dataset.themeChoice === current.id));
    }
  }

  function render() {
    return `<section class="panel club-panel ios-panel turc-appearance" aria-labelledby="turc-appearance-title">
      <h2 id="turc-appearance-title">Appearance</h2>
      <p class="club-note">Your theme follows your TURC account.</p>
      <div class="turc-theme-options">${options.map(({ id, label }) => `
        <button type="button" class="btn outline turc-theme-option" data-action="appearance" data-theme-choice="${id}" aria-pressed="${id === current.id}">
          <span class="turc-theme-swatch" data-swatch="${id}" aria-hidden="true"></span>${label}
        </button>`).join('')}</div>
    </section>`;
  }

  async function save(client, user, choice) {
    if (!options.some(option => option.id === choice) || choice === current.id) return user;
    const { data, error } = await client.auth.updateUser({ data: { turc_theme: choice } });
    if (error) throw error;
    if (data?.user?.id !== user.id) throw Error('The theme could not be saved. Sign in and try again.');
    return data.user;
  }

  window.TurcAppearance = { apply, render, save, get theme() { return current.id; } };
})();
