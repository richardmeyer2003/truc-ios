import { credentialPattern } from './scan-contract.mjs';

const scripts = new Map();

function loadScript(path, globalName) {
  if (window[globalName]) return Promise.resolve(window[globalName]);
  if (!scripts.has(path)) {
    scripts.set(path, new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = path;
      script.onload = () => window[globalName] ? resolve(window[globalName]) : reject(Error('Badge tools could not load.'));
      script.onerror = () => reject(Error('Badge tools could not load.'));
      document.head.append(script);
    }).catch(error => {
      scripts.delete(path);
      throw error;
    }));
  }
  return scripts.get(path);
}

async function badgeCode(token) {
  if (!credentialPattern.test(token)) throw Error('This student needs an assigned badge.');
  const qrcode = await loadScript('/vendor/qrcode-generator-1.4.4.js', 'qrcode');
  const code = qrcode(0, 'M');
  code.addData(token);
  code.make();
  return code;
}

export async function qrImage({ token }) {
  const code = await badgeCode(token);
  return { dataURL: code.createDataURL(8, 32) };
}

export async function shareBadgePDF(badge) {
  const [{ PDFDocument, StandardFonts, rgb }, code] = await Promise.all([
    loadScript('/vendor/pdf-lib-1.17.1.js', 'PDFLib'), badgeCode(badge.token)
  ]);
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([612, 792]);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const green = rgb(.14, .42, .38);
  const grey = rgb(.5, .5, .5);
  page.drawText('TURC runner badge', { x: 48, y: 727, size: 20, font: bold, color: green });
  page.drawText('Print at 100% / Actual Size on US Letter. Finished insert: 2.52 x 3.54 inches.', {
    x: 48, y: 699, size: 11, font
  });

  const width = 2.52 * 72;
  const height = 3.54 * 72;
  const x = (page.getWidth() - width) / 2;
  const y = (page.getHeight() - height) / 2;
  page.drawRectangle({ x, y, width, height, borderColor: grey, borderWidth: .5 });
  page.drawRectangle({ x, y: y + height - 4, width, height: 4, color: green });

  // Draw student text with browser fonts to retain accents and non-Latin names.
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(width * 4);
  canvas.height = 125 * 4;
  const ctx = canvas.getContext('2d');
  ctx.scale(4, 4);
  const textWidth = width - 28;
  function label(text, baseline, size, heavy = false) {
    ctx.fillStyle = heavy ? '#246b61' : '#202020';
    ctx.font = `${heavy ? '700' : '400'} ${size}px system-ui, sans-serif`;
    ctx.fillText(text || '', 14, baseline, textWidth);
  }
  label('TURC', 23, 11, true);
  label(badge.school_name, 40, 10);
  label(badge.student_name, 68, 18, true);
  label([badge.grade && `Grade ${badge.grade}`, badge.classroom].filter(Boolean).join(' · '), 91, 10);
  label(`ID ${badge.student_number || ''}`, 110, 10);
  const labels = await pdf.embedPng(canvas.toDataURL('image/png'));
  page.drawImage(labels, { x, y: y + height - 125, width, height: 125 });

  const qrSize = 106;
  const span = code.getModuleCount();
  const module = qrSize / (span + 8);
  const qrX = x + (width - qrSize) / 2;
  const qrY = y + 16;
  const black = rgb(0, 0, 0);
  for (let row = 0; row < span; row++) {
    for (let column = 0; column < span; column++) {
      if (!code.isDark(row, column)) continue;
      page.drawRectangle({ x: qrX + (column + 4) * module, y: qrY + (span + 3 - row) * module,
        width: module, height: module, color: black });
    }
  }

  const url = URL.createObjectURL(new Blob([await pdf.save()], { type: 'application/pdf' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'TURC-runner-badge.pdf';
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
