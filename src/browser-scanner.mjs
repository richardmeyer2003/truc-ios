import { credentialPattern } from './scan-contract.mjs';
import { walkCodePattern } from './walkathon.mjs';

export function createBrowserScanner() {
  const listeners = { scan: new Set(), closed: new Set() };
  const photoContext = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
  const template = document.createElement('template');
  template.innerHTML = `<dialog class="web-scan" aria-labelledby="web-scan-title">
    <header>
      <div><h2 id="web-scan-title">Scan QR code</h2><p class="web-scan-scope"></p></div>
      <button type="button" class="btn outline" data-close>Done</button>
    </header>
    <div class="web-scan-preview" hidden>
      <video muted playsinline aria-hidden="true"></video>
      <canvas role="img" aria-label="Live camera preview"></canvas>
      <div class="web-scan-guide" aria-hidden="true"></div>
    </div>
    <p data-camera-status></p>
    <div class="web-scan-actions">
      <button type="button" class="btn" data-camera>Start camera</button>
      <button type="button" class="btn outline" data-choose>Choose QR photo</button>
      <input type="file" accept="image/*" hidden>
    </div>
    <div class="web-scan-result" role="status" aria-live="polite">
      <strong></strong><span data-student></span><span data-detail></span>
    </div>
  </dialog>`;
  let current = null;

  function emit(type, event) {
    for (const listener of listeners[type]) listener(event);
  }

  function drawFrame(context, image, width, height) {
    const { canvas } = context;
    const scale = Math.min(1, 1440 / Math.max(width, height));
    const w = Math.max(1, Math.round(width * scale));
    const h = Math.max(1, Math.round(height * scale));
    if (canvas.width !== w) canvas.width = w;
    if (canvas.height !== h) canvas.height = h;
    context.drawImage(image, 0, 0, w, h);
  }

  function decode(context) {
    const { width, height } = context.canvas;
    return window.jsQR(context.getImageData(0, 0, width, height).data, width, height)?.data;
  }

  function clearFrame(context) {
    context.canvas.width = 1;
    context.canvas.height = 1;
  }

  function show(session, title, detail = '', state = '', student = '') {
    if (session !== current) return;
    session.result.hidden = false;
    session.result.dataset.state = state;
    session.result.querySelector('strong').textContent = title;
    session.result.querySelector('[data-student]').textContent = student;
    session.result.querySelector('[data-detail]').textContent = detail;
  }

  function read(session, value) {
    if (session !== current || session.waiting) return;
    if (!value) {
      show(session, 'No QR code found', 'Try a clearer photo of the badge or bib.', 'rejected');
      return;
    }
    const walk = session.mode === 'walkathon';
    if (!(walk ? walkCodePattern : credentialPattern).test(value)) {
      show(session, walk ? 'Use a Walk-a-thon bib' : 'Use a TURC student badge', 'No lap added.', 'rejected');
      return;
    }
    session.waiting = true;
    session.choose.disabled = true;
    show(session, 'Checking lap…');
    emit('scan', {
      runID: session.runID, value, source: 'qr',
      eventID: crypto.randomUUID(), observedAt: new Date().toISOString()
    });
  }

  function scanFrame(session, now) {
    if (session !== current || !session.stream) return;
    session.frame = requestAnimationFrame(next => scanFrame(session, next));
    const { video, previewContext } = session;
    if (video.readyState < 2 || !video.videoWidth || !video.videoHeight || now < session.nextPreview) return;
    session.nextPreview = now + 40;
    // Safari can keep delivering camera frames while its video layer paints black.
    drawFrame(previewContext, video, video.videoWidth, video.videoHeight);
    if (now < session.nextScan || session.readingPhoto) return;
    session.nextScan = now + 150;
    const value = decode(previewContext);
    if (!value) return;
    if (session.waiting && value !== session.lastCode) return;
    const heldInPlace = value === session.lastCode && now - session.lastSeen < 650;
    session.lastCode = value;
    session.lastSeen = now;
    if (!heldInPlace) read(session, value);
  }

  function stopCamera(session, message = '') {
    session.cameraRequest++;
    cancelAnimationFrame(session.frame);
    session.stream?.getTracks().forEach(track => track.stop());
    session.stream = null;
    session.video.srcObject = null;
    session.preview.hidden = true;
    clearFrame(session.previewContext);
    session.camera.disabled = false;
    session.camera.textContent = 'Start camera';
    session.cameraStatus.textContent = message;
  }

  async function startCamera(session) {
    if (session !== current) return;
    if (!navigator.mediaDevices?.getUserMedia) {
      session.camera.disabled = true;
      session.cameraStatus.textContent = 'Camera access is unavailable here. Choose a QR photo to scan it.';
      return;
    }
    const request = ++session.cameraRequest;
    const isActive = () => session === current && request === session.cameraRequest;
    session.camera.disabled = true;
    session.cameraStatus.textContent = 'Waiting for camera access…';
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' } } });
      if (!isActive()) {
        stream.getTracks().forEach(track => track.stop());
        return;
      }
      session.stream = stream;
      session.video.muted = true;
      session.video.srcObject = stream;
      session.preview.hidden = false;
      await session.video.play();
      if (!isActive()) return;
      session.camera.textContent = 'Stop camera';
      session.camera.disabled = false;
      session.cameraStatus.textContent = 'Hold the QR code inside the frame.';
      session.frame = requestAnimationFrame(now => scanFrame(session, now));
      for (const track of stream.getVideoTracks()) {
        track.addEventListener('ended', () => {
          if (isActive()) stopCamera(session, 'Camera disconnected. Start it again or choose a QR photo.');
        }, { once: true });
      }
    } catch (error) {
      if (!isActive()) return;
      const message = error.name === 'NotAllowedError'
        ? 'Allow camera access in your browser settings, or choose a QR photo.'
        : 'Could not open the camera. Try again or choose a QR photo.';
      stopCamera(session, message);
    }
  }

  async function readPhoto(session, file) {
    if (!file || session !== current || session.waiting || session.readingPhoto) return;
    session.readingPhoto = true;
    session.choose.disabled = true;
    const url = URL.createObjectURL(file);
    try {
      const image = new Image();
      image.src = url;
      await image.decode();
      if (session === current) {
        drawFrame(photoContext, image, image.naturalWidth, image.naturalHeight);
        read(session, decode(photoContext));
      }
    } catch {
      show(session, 'Could not open this photo', 'Choose a PNG or JPEG photo of the QR code.', 'rejected');
    } finally {
      URL.revokeObjectURL(url);
      clearFrame(photoContext);
      session.readingPhoto = false;
      session.choose.disabled = session.waiting;
    }
  }

  function dismiss(session) {
    if (session !== current) return;
    current = null;
    stopCamera(session);
    session.dialog.close();
    session.dialog.remove();
    emit('closed', { runID: session.runID });
  }

  document.addEventListener('visibilitychange', () => {
    if (document.hidden && current && (current.stream || current.camera.disabled)) {
      stopCamera(current, 'Camera paused. Start it again to keep scanning.');
    }
  });
  window.addEventListener('pagehide', () => { if (current) dismiss(current); });

  return {
    addListener(type, listener) { listeners[type].add(listener); },
    async open({ runID, school, mode }) {
      if (!photoContext || !window.jsQR) throw Error('The QR scanner did not load. Refresh the page and try again.');
      if (mode !== 'qr' && mode !== 'walkathon') throw Error('Choose a QR scanner.');
      if (current) dismiss(current);
      const dialog = template.content.firstElementChild.cloneNode(true);
      const previewContext = dialog.querySelector('canvas').getContext('2d', { willReadFrequently: true });
      if (!previewContext) throw Error('Could not load the camera preview.');
      const session = {
        runID, mode, dialog, previewContext, video: dialog.querySelector('video'),
        preview: dialog.querySelector('.web-scan-preview'), camera: dialog.querySelector('[data-camera]'),
        cameraStatus: dialog.querySelector('[data-camera-status]'), choose: dialog.querySelector('[data-choose]'),
        result: dialog.querySelector('.web-scan-result'), cameraRequest: 0, nextPreview: 0, nextScan: 0, lastSeen: 0
      };
      current = session;
      const input = dialog.querySelector('input');
      session.result.hidden = true;
      dialog.querySelector('.web-scan-scope').textContent = school;
      dialog.querySelector('[data-close]').addEventListener('click', () => dismiss(session));
      dialog.addEventListener('close', () => dismiss(session));
      session.camera.addEventListener('click', () => {
        if (session.stream) stopCamera(session, 'Camera paused.');
        else void startCamera(session);
      });
      session.choose.addEventListener('click', () => input.click());
      input.addEventListener('change', () => {
        const file = input.files[0];
        input.value = '';
        void readPhoto(session, file);
      });
      document.body.append(dialog);
      dialog.showModal();
      void startCamera(session);
    },
    async feedback({ runID, title, detail, student, accepted, pending }) {
      if (current?.runID !== runID) return;
      current.waiting = Boolean(pending);
      current.choose.disabled = current.waiting || current.readingPhoto;
      show(current, title, detail, accepted ? 'accepted' : 'rejected', student);
    },
    async close() { if (current) dismiss(current); }
  };
}
