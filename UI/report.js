/* Lays the IT report out as US Letter pages. MacSense calls renderReport(report) and gets back the
   page count; it then renders the stacked pages to PDF and cuts them apart. */
(function () {
  'use strict';

  const WORDS = { good: 'OK', warning: 'Check', critical: 'Needs attention', info: 'Info', locked: 'Admin needed' };

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;   // names and values come from the system: never parsed as HTML
    return node;
  }

  function stamp(ms) {
    return new Date(ms).toLocaleString([], { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  }

  function header(report) {
    const head = el('header', 'report-head');
    const left = el('div');
    const brand = el('div', 'brand');
    brand.append(el('i'), document.createTextNode('MACSENSE'));
    left.append(brand, el('h1', null, 'Mac health report'), el('p', 'machine', `${report.computer} · ${report.model}`));
    const facts = el('div', 'facts');
    for (const [label, value] of [['Serial', report.serial], ['Scanned', stamp(report.generated)], ['MacSense', 'v' + report.appVersion]]) {
      const line = el('div');
      line.append(document.createTextNode(label + ' '), el('strong', null, value));
      facts.append(line);
    }
    head.append(left, facts);
    return head;
  }

  function summary(report) {
    const box = el('div', 'summary');
    const s = report.summary;
    const cells = [[s.critical, 'need attention'], [s.warning, 'to check'], [s.good, 'OK']];
    if (s.locked) cells.push([s.locked, 'need an admin password']);
    for (const [count, label] of cells) {
      const cell = el('div');
      cell.append(el('strong', null, String(count)), el('span', null, label));
      box.append(cell);
    }
    return box;
  }

  function row(item) {
    const line = el('div', 'row ' + item.status);
    const status = el('div', 'status ' + item.status);
    status.append(el('i'), document.createTextNode(WORDS[item.status] || item.status));
    const what = el('div', 'item-title', item.title);
    const body = el('div');
    body.append(el('div', 'item-value', item.value));
    if (item.detail) body.append(el('div', 'item-detail', item.detail));
    if (item.fix) body.append(el('div', 'item-fix', item.fix));
    line.append(status, what, body);
    return line;
  }

  /** The report as a list of blocks that must not be split across pages. A section title travels with its first row. */
  function blocks(report) {
    const intro = el('div');
    intro.append(summary(report), el('p', 'privacy', `Collected: ${report.privacy} Nothing leaves this Mac unless someone sends this report.`));
    const list = [header(report), intro];
    for (const section of report.sections) {
      section.items.forEach((item, index) => {
        if (index === 0) {
          const group = el('div');
          group.append(el('h2', 'section-title', section.title), row(item));
          list.push(group);
        } else {
          list.push(row(item));
        }
      });
    }
    return list;
  }

  window.renderReport = function (report) {
    const pages = document.getElementById('pages');
    const measurePage = document.getElementById('measure');
    const measureBody = measurePage.querySelector('.page-body');
    pages.replaceChildren();
    // The usable body height: a full page minus its padding and footer. The probe footer stays in place
    // so the body keeps exactly that height while blocks are measured.
    measureBody.replaceChildren();
    measurePage.append(el('div', 'page-footer', 'x'));
    const limit = measureBody.clientHeight;
    // Content is measured in its own box ('flow-root' keeps the blocks' margins inside it), never by
    // the body, which stretches to fill the page whatever it holds.
    const content = el('div');
    content.style.display = 'flow-root';
    measureBody.append(content);

    // Fill a page block by block; the first block that doesn't fit starts the next page.
    const bodies = [];
    let current = [];
    for (const block of blocks(report)) {
      content.append(block);
      if (content.offsetHeight > limit && current.length) {
        bodies.push(current);
        content.replaceChildren(block);
        current = [block];
      } else {
        current.push(block);
      }
    }
    if (current.length) bodies.push(current);

    bodies.forEach((content, index) => {
      const page = el('section', 'page');
      const pageBody = el('div', 'page-body');
      pageBody.append(...content);
      const footer = el('div', 'page-footer');
      footer.append(
        el('span', null, `MacSense report · ${report.computer} · serial ${report.serial}`),
        el('span', null, `Page ${index + 1} of ${bodies.length}`),
      );
      page.append(pageBody, footer);
      pages.append(page);
    });
    document.getElementById('measure').remove();
    return bodies.length;
  };
})();
