(function (root) {
  'use strict';
  function parse(text) {
    const rows = []; let row = [], cell = '', quoted = false, closed = false;
    text = String(text).replace(/^\uFEFF/, '');
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (quoted) {
        if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; }
        else if (c === '"') { quoted = false; closed = true; }
        else cell += c;
      } else if (c === '"') {
        if (cell || closed) throw Error('Unexpected quotation mark. Check your CSV formatting.');
        quoted = true;
      } else if (c === ',' || c === '\n' || c === '\r') {
        row.push(cell); cell = ''; closed = false;
        if (c !== ',') {
          if (c === '\r' && text[i + 1] === '\n') i++;
          if (row.some(v => v.trim())) rows.push(row);
          row = [];
        }
      } else {
        if (closed && !/\s/.test(c)) throw Error('Unexpected text after a quoted value.');
        if (!closed) cell += c;
      }
    }
    if (quoted) throw Error('A quoted value is missing its closing quotation mark.');
    row.push(cell); if (row.some(v => v.trim())) rows.push(row);
    if (rows.length < 2) throw Error('Include a header row and at least one student.');
    const width = rows[0].length;
    if (rows.slice(1).some(r => r.length !== width)) throw Error('Each row must have the same number of columns as the header.');
    if (rows[0].some(h => !h.trim())) throw Error('Every column needs a header.');
    if (new Set(rows[0].map(h => h.trim().toLowerCase())).size !== width) throw Error('Column headers must be unique.');
    if (rows.length > 1001) throw Error('Import up to 1,000 students at a time.');
    return { headers: rows[0].map(h => h.trim()), rows: rows.slice(1) };
  }
  function mapRows(parsed, mapping) {
    const fields = ['student_id', 'first_name', 'last_name', 'grade', 'classroom'];
    const indexes = fields.map(f => mapping[f]).filter(i => i !== '' && i !== undefined && i !== null).map(Number);
    if (new Set(indexes).size !== indexes.length) throw Error('Map each CSV column only once.');
    for (const f of fields.slice(0, 3)) if (mapping[f] === '' || mapping[f] === undefined) throw Error('Map Student ID, First Name, and Last Name.');
    return parsed.rows.map(row => Object.fromEntries(fields.filter(f => mapping[f] !== '' && mapping[f] !== undefined && mapping[f] !== null)
      .map(f => { const index = Number(mapping[f]); if (!Number.isInteger(index) || index < 0 || index >= parsed.headers.length) throw Error('Invalid column mapping.'); return [f, row[index].trim()]; })));
  }
  function suggest(headers) {
    const aliases = { student_id: ['student id', 'student_id', 'id'], first_name: ['first name', 'first_name', 'first'], last_name: ['last name', 'last_name', 'last'], grade: ['grade'], classroom: ['classroom', 'teacher', 'teacher/homeroom', 'homeroom'] };
    return Object.fromEntries(Object.entries(aliases).map(([key, values]) => { const i = headers.findIndex(h => values.includes(h.toLowerCase())); return [key, i < 0 ? '' : String(i)]; }));
  }
  function cell(value) { let s = String(value ?? ''); if (/^[\s]*[=+\-@\t\r]/.test(s)) s = "'" + s; return '"' + s.replace(/"/g, '""') + '"'; }
  const api = { parse, mapRows, suggest, cell };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.TurcCSV = api;
})(typeof window !== 'undefined' ? window : globalThis);
