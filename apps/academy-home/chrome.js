(function () {
  var fab = document.querySelector('.fab');
  if (fab) {
    var compact = false;
    var frame = 0;
    function syncFab() {
      frame = 0;
      var next = (window.scrollY || document.documentElement.scrollTop || 0) > 24;
      if (next === compact) return;
      compact = next;
      fab.classList.toggle('is-compact', compact);
    }
    window.addEventListener('scroll', function () {
      if (frame) return;
      frame = window.requestAnimationFrame(syncFab);
    }, { passive: true });
    syncFab();
  }

  var menu = document.querySelector('#menu-panel');
  var search = document.querySelector('#search-panel');
  var menuButton = document.querySelector('#open-menu');
  var input = document.querySelector('#site-search');
  var list = document.querySelector('#search-list');
  var empty = document.querySelector('#search-empty');
  if (!menu || !search || !menuButton || !input || !list || !empty) return;

  var pages = [
    { name: '공지', href: '/notices', keys: '공지' },
    { name: '위치', href: '/location', keys: '위치 지도' },
    { name: '신규 상담', href: '/consult', keys: '상담 신규' }
  ];

  function closePanels() {
    menu.hidden = true;
    search.hidden = true;
    menuButton.setAttribute('aria-expanded', 'false');
    document.body.style.overflow = '';
  }

  function openPanel(panel) {
    closePanels();
    panel.hidden = false;
    document.body.style.overflow = 'hidden';
    if (panel === menu) menuButton.setAttribute('aria-expanded', 'true');
  }

  function renderSearch() {
    var query = input.value.trim();
    var found = pages.filter(function (page) {
      return !query || (page.name + page.keys).indexOf(query) !== -1;
    });
    list.innerHTML = found.map(function (page) {
      return '<a href="' + page.href + '">' + page.name + '</a>';
    }).join('');
    empty.hidden = found.length > 0;
  }

  document.querySelector('#open-menu').addEventListener('click', function () {
    openPanel(menu);
    menu.querySelector('[data-close]').focus();
  });
  document.querySelector('#open-search').addEventListener('click', function () {
    input.value = '';
    renderSearch();
    openPanel(search);
    input.focus();
  });
  document.querySelectorAll('[data-close]').forEach(function (button) {
    button.addEventListener('click', closePanels);
  });
  input.addEventListener('input', renderSearch);
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') closePanels();
  });
})();
