// Edits this browser's camera picture before it is sent: brightness, black and
// white, and covering faces. The web twin of CameraFx.kt.
//
// Draws on a 2D canvas with blend modes because Safari has no canvas filters.
// Faces are found by MediaPipe tasks-vision 1.0.0 (Apache-2.0) in fx/, which only
// downloads the first time someone turns face blur on. Nothing leaves the browser.
window.dardashaFx = (() => {
  const FRAME_MS = 33;
  const DETECT_EVERY_MS = 150;
  // Faces move and a detection can miss one, so a lost face stays covered this long.
  const KEEP_FACE_MS = 1000;
  const MOSAIC_BLOCKS = 7;
  const COVER_BLOCKS = 12;

  const settings = { brightness: 0, gray: 0, blur: false };
  let run = null;
  let detector = null;
  let loading = null;

  function loadDetector() {
    return (loading ??= (async () => {
      const fx = new URL('fx/', document.baseURI).href;
      const { FaceDetector } = await import(`${fx}vision_bundle.mjs`);
      detector = await FaceDetector.createFromOptions(
        { wasmLoaderPath: `${fx}vision_wasm_internal.js`, wasmBinaryPath: `${fx}vision_wasm_internal.wasm` },
        {
          baseOptions: { modelAssetPath: `${fx}blaze_face_short_range.tflite`, delegate: 'CPU' },
          runningMode: 'VIDEO',
          minDetectionConfidence: 0.4,
        },
      );
    })().catch((e) => console.error('face detector', e)));
  }

  function detect(r, now) {
    if (now - r.detectedAt < DETECT_EVERY_MS) return;
    r.detectedAt = now;
    try {
      const found = detector.detectForVideo(r.video, now).detections;
      if (found.length > 0) {
        r.faces = found.map((f) => f.boundingBox);
        r.facesAt = now;
      } else if (now - r.facesAt > KEEP_FACE_MS) {
        r.faces = [];
      }
    } catch (e) {
      console.error('face detection', e);
      detector = null; // without it the whole picture stays covered
    }
  }

  function mosaic(r, x, y, w, h, blocks) {
    const left = Math.max(0, x);
    const top = Math.max(0, y);
    const width = Math.min(r.canvas.width, x + w) - left;
    const height = Math.min(r.canvas.height, y + h) - top;
    if (width <= 0 || height <= 0) return;
    const scale = blocks / Math.max(width, height);
    const tinyW = Math.max(1, Math.round(width * scale));
    const tinyH = Math.max(1, Math.round(height * scale));
    r.tiny.width = tinyW;
    r.tiny.height = tinyH;
    r.tiny.getContext('2d').drawImage(r.canvas, left, top, width, height, 0, 0, tinyW, tinyH);
    r.ctx.imageSmoothingEnabled = false;
    r.ctx.drawImage(r.tiny, 0, 0, tinyW, tinyH, left, top, width, height);
    r.ctx.imageSmoothingEnabled = true;
  }

  function fill(ctx, w, h, mode, color, alpha = 1) {
    ctx.globalCompositeOperation = mode;
    ctx.globalAlpha = alpha;
    ctx.fillStyle = color;
    ctx.fillRect(0, 0, w, h);
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
  }

  function draw(r) {
    const { video, canvas, ctx } = r;
    if (video.readyState < 2 || video.videoWidth === 0) return;
    if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
    }
    const w = canvas.width;
    const h = canvas.height;
    ctx.drawImage(video, 0, 0, w, h);

    if (settings.blur) {
      if (detector) detect(r, performance.now());
      // Until the detector is ready (or if it can't load) nothing shows, rather than a face.
      if (!detector) {
        mosaic(r, 0, 0, w, h, COVER_BLOCKS);
      } else {
        for (const f of r.faces) {
          const padX = f.width * 0.3;
          const padY = f.height * 0.3;
          mosaic(r, f.originX - padX, f.originY - padY, f.width + padX * 2, f.height + padY * 2, MOSAIC_BLOCKS);
        }
      }
    }
    if (settings.gray > 0) fill(ctx, w, h, 'saturation', '#000', settings.gray);
    if (settings.brightness > 0) {
      const v = Math.round(settings.brightness * 110);
      fill(ctx, w, h, 'lighter', `rgb(${v},${v},${v})`);
    } else if (settings.brightness < 0) {
      const v = Math.round(255 * (1 + settings.brightness * 0.75));
      fill(ctx, w, h, 'multiply', `rgb(${v},${v},${v})`);
    }
  }

  return {
    available: typeof HTMLCanvasElement.prototype.captureStream === 'function',

    set(brightness, gray, blur) {
      settings.brightness = brightness;
      settings.gray = gray;
      settings.blur = blur;
      if (blur) loadDetector();
      if (!blur && run) run.faces = [];
    },

    /// The edited picture of [camera], as a new stream.
    start(camera) {
      this.stop();
      const video = document.createElement('video');
      video.muted = true;
      video.playsInline = true;
      // iOS pauses a video that isn't on the page.
      video.style.cssText = 'position:fixed;width:1px;height:1px;opacity:0;pointer-events:none';
      document.body.appendChild(video);
      video.srcObject = camera;
      video.play().catch((e) => console.error('camera fx', e));

      const canvas = document.createElement('canvas');
      const size = camera.getVideoTracks()[0]?.getSettings() ?? {};
      canvas.width = size.width || 640;
      canvas.height = size.height || 480;
      const ctx = canvas.getContext('2d', { alpha: false });
      const output = canvas.captureStream(30);
      const r = { video, canvas, ctx, output, tiny: document.createElement('canvas'), faces: [], facesAt: 0, detectedAt: 0 };
      // A timer, since animation frames stop while the tab is in the background.
      r.timer = setInterval(() => draw(r), FRAME_MS);
      draw(r);
      run = r;
      return output;
    },

    stop() {
      if (!run) return;
      clearInterval(run.timer);
      for (const t of run.output.getTracks()) t.stop();
      run.video.srcObject = null;
      run.video.remove();
      run = null;
    },
  };
})();
