(() => {
  const path = location.pathname.replace(/\.html$/, '').replace(/\/$/, '') || '/index';
  const demo = new URLSearchParams(location.search).get('demo') === '1';
  document.querySelectorAll('.ps-nav nav a').forEach(a => {
    const target = new URL(a.href);
    const targetPath = target.pathname.replace(/\.html$/, '').replace(/\/$/, '') || '/index';
    if(target.origin === location.origin && targetPath === path && (target.searchParams.get('demo') === '1') === demo) a.setAttribute('aria-current','page');
  });
  document.querySelector('.motion-toggle')?.addEventListener('click', e => {
    const paused = document.querySelector('.machine').classList.toggle('motion-paused');
    e.currentTarget.setAttribute('aria-pressed', String(paused));
    e.currentTarget.textContent = paused ? 'Resume motion' : 'Pause motion';
  });
})();
