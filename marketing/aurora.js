(function () {
  'use strict';

  var DUR = 12;
  var REGIONS = [[0, 1.1, 's'], [1.1, 4.0, 'v'], [4.0, 4.7, 's'], [4.7, 8.4, 'v'], [8.4, 9.9, 's'], [9.9, 11.2, 'v'], [11.2, 12, 's']];
  var seed = 7;
  function rnd() { seed = (seed * 16807) % 2147483647; return seed / 2147483647; }
  var RATE = 200;
  var N = DUR * RATE;
  var env = new Float32Array(N);
  (function bake() {
    var syl = 0;
    var sylLen = 0;
    var sylAmp = 0;
    for (var i = 0; i < N; i++) {
      var time = i / RATE;
      var region = null;
      for (var k = 0; k < REGIONS.length; k++) {
        if (time >= REGIONS[k][0] && time < REGIONS[k][1]) region = REGIONS[k];
      }
      if (!region || region[2] === 's') {
        env[i] = 0.02 + 0.015 * rnd();
        continue;
      }
      if (syl <= 0) {
        sylLen = 0.12 + rnd() * 0.2;
        syl = sylLen;
        sylAmp = 0.45 + rnd() * 0.55;
      }
      var ph = 1 - syl / sylLen;
      var shape = Math.pow(Math.sin(Math.PI * Math.min(1, ph * 1.25)), 0.8);
      env[i] = 0.05 + sylAmp * shape * (0.85 + 0.3 * rnd());
      syl -= 1 / RATE;
    }
  })();
  function envAt(time) {
    return env[Math.max(0, Math.min(N - 1, Math.floor((time % DUR) * RATE)))];
  }
  function isSpeakingAt(time) {
    var loopTime = ((time % DUR) + DUR) % DUR;
    for (var i = 0; i < REGIONS.length; i++) {
      if (loopTime >= REGIONS[i][0] && loopTime < REGIONS[i][1]) return REGIONS[i][2] === 'v';
    }
    return false;
  }

  var RESPONSIVENESS = 0.6;
  var GLOW = 0.7;
  var P = { amber: '#FFB347', coral: '#FF5E8A', magenta: '#C64BFF', violet: '#6B5BFF', cyan: '#3FD6FF' };
  var AURORA = [
    { c: P.amber, f: 1.0, a: 0.55, w: 1.2, ph: 0.0 },
    { c: P.coral, f: 1.35, a: 0.8, w: 1.4, ph: 1.1 },
    { c: P.magenta, f: 1.7, a: 1.0, w: 1.6, ph: 2.3 },
    { c: P.violet, f: 2.1, a: 0.75, w: 1.3, ph: 3.4 },
    { c: P.cyan, f: 2.6, a: 0.5, w: 1.1, ph: 4.6 }
  ];
  var SPEC = {
    strands: AURORA,
    glowMul: 1.0,
    orbit: { core: 0.0, radiusSpread: 0.28, glow: 0.9, hueDrift: 0 }
  };
  var STATE_TARGET = {
    listening: { wave: 1, orbit: 0, sweep: 0 },
    transcribing: { wave: 0, orbit: 0, sweep: 1 },
    cleaning: { wave: 0, orbit: 1, sweep: 0 },
    done: { wave: 0, orbit: 0, sweep: 0 }
  };

  function smooth(previous, target, delta) {
    var attack = 12 + RESPONSIVENESS * 40;
    var release = 3 + RESPONSIVENESS * 9;
    var rate = target > previous ? attack : release;
    return previous + (target - previous) * Math.min(1, rate * delta);
  }

  function ease(previous, target, delta, rate) {
    return previous + (target - previous) * Math.min(1, rate * delta);
  }

  function strokeStrand(ctx, colour, strand, scale, pixelScale, glowAmount, coreAlpha) {
    ctx.strokeStyle = colour;
    ctx.lineWidth = strand.w * scale;
    ctx.lineCap = 'round';
    ctx.shadowColor = colour;
    ctx.shadowBlur = (2 + GLOW * 10 * SPEC.glowMul) * scale * glowAmount;
    ctx.globalAlpha = 0.85;
    ctx.stroke();
    if (coreAlpha > 0.02) {
      ctx.shadowBlur = 0;
      ctx.lineWidth = Math.max(0.6 * pixelScale, strand.w * scale * 0.45);
      ctx.globalAlpha = 0.95 * coreAlpha;
      ctx.stroke();
    }
  }

  function drawStrands(wave, level, delta) {
    var ctx = wave.ctx;
    var width = wave.canvas.width;
    var height = wave.canvas.height;
    var orbitSpec = SPEC.orbit;
    var pixelScale = wave.dpr / 2;
    var scale = wave.scale * pixelScale;
    var middle = height / 2;
    var padding = width * 0.06;
    var span = width - padding * 2;
    var strandCount = SPEC.strands.length;
    wave.drift += delta;

    var target = STATE_TARGET[wave.state] || STATE_TARGET.listening;
    wave.blend.wave = ease(wave.blend.wave, target.wave, delta, 9);
    wave.blend.orbit = ease(wave.blend.orbit, target.orbit, delta, 5);
    wave.blend.sweep = ease(wave.blend.sweep, target.sweep, delta, 6);
    wave.blend.sweepT = (wave.blend.sweepT + delta / 0.7) % 1;
    wave.blend.hue = (wave.blend.hue + delta * orbitSpec.hueDrift * wave.blend.orbit) % 360;

    var amplitude = Math.max(wave.idleFloor, level) * wave.blend.wave;
    wave.phase += delta * (2.5 + level * 9) * (0.3 + 0.7 * wave.blend.wave) + delta * 2.6 * wave.blend.orbit;
    var radius = height * 0.34;
    var centreX = width / 2;
    var orbit = wave.blend.orbit;

    ctx.globalCompositeOperation = 'lighter';
    for (var strandIndex = 0; strandIndex < strandCount; strandIndex++) {
      var strand = SPEC.strands[strandIndex];
      var strandRadius = radius * (1 - orbitSpec.radiusSpread / 2 + orbitSpec.radiusSpread * (strandIndex / (strandCount - 1)));
      ctx.beginPath();
      for (var x = 0; x <= span; x += pixelScale) {
        var progress = x / span;
        var windowing = Math.sin(Math.PI * progress);
        var oscillation = Math.sin(progress * Math.PI * 2 * strand.f + wave.phase * (0.7 + 0.3 * strandIndex / strandCount) + strand.ph);
        var lineX = padding + x;
        var lineY = middle + oscillation * windowing * amplitude * strand.a * (height * 0.46);
        var angle = progress * Math.PI * 2 + wave.phase * 0.9 + strand.ph;
        var wobble = 1 + 0.10 * Math.sin(progress * Math.PI * 6 + wave.phase * 1.5 + strandIndex);
        var orbitX = centreX + Math.cos(angle) * strandRadius * wobble;
        var orbitY = middle + Math.sin(angle) * strandRadius * wobble;
        var pointX = lineX + (orbitX - lineX) * orbit;
        var pointY = lineY + (orbitY - lineY) * orbit;
        if (x) ctx.lineTo(pointX, pointY);
        else ctx.moveTo(pointX, pointY);
      }
      var glowAmount = (0.4 + amplitude) * (1 - orbit) + orbitSpec.glow * (0.6 + 0.4 * Math.sin(wave.drift * 2 + strandIndex)) * orbit;
      var coreAlpha = 1 - orbit * (1 - orbitSpec.core);
      strokeStrand(ctx, strand.c, strand, scale, pixelScale, glowAmount, coreAlpha);
    }

    if (wave.blend.sweep > 0.02) {
      var sweepWidth = 0.18;
      var head = wave.blend.sweepT * (1 + sweepWidth) - sweepWidth;
      for (var sweepIndex = 0; sweepIndex < strandCount; sweepIndex++) {
        var sweepStrand = SPEC.strands[sweepIndex];
        var start = Math.max(0, head - sweepWidth * (1 - sweepIndex / strandCount) * 0.6);
        var end = Math.min(1, head + sweepWidth * 0.35);
        if (end <= start) continue;
        ctx.beginPath();
        ctx.moveTo(padding + start * span, middle);
        ctx.lineTo(padding + end * span, middle);
        ctx.strokeStyle = sweepStrand.c;
        ctx.lineCap = 'round';
        ctx.lineWidth = sweepStrand.w * 1.6 * scale;
        ctx.shadowColor = sweepStrand.c;
        ctx.shadowBlur = (6 + GLOW * 14) * scale;
        ctx.globalAlpha = 0.9 * wave.blend.sweep * (1 - orbit);
        ctx.stroke();
      }
    }

    ctx.globalAlpha = 1;
    ctx.shadowBlur = 0;
    ctx.globalCompositeOperation = 'source-over';
  }

  function mountAurora(canvas, opts) {
    opts = opts || {};
    if (!(canvas instanceof HTMLCanvasElement)) throw new TypeError('mountAurora requires a canvas element');
    if (canvas.__aurora && canvas.__aurora.destroy) canvas.__aurora.destroy();

    var ctx = canvas.getContext('2d');
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var state = STATE_TARGET[opts.state] ? opts.state : 'listening';
    var wave = {
      canvas: canvas,
      ctx: ctx,
      dpr: Math.max(1, window.devicePixelRatio || 1),
      scale: typeof opts.scale === 'number' ? opts.scale : 1,
      idleFloor: typeof opts.idleFloor === 'number' ? Math.max(0, opts.idleFloor) : 0.05,
      silenceScale: typeof opts.silenceScale === 'number' ? Math.max(0, opts.silenceScale) : 1,
      state: state,
      level: envAt(2.5),
      phase: 0,
      drift: 0,
      blend: { wave: 1, orbit: 0, sweep: 0, sweepT: 0, hue: 0 }
    };
    var elapsed = 2.5;
    var onTick = typeof opts.onTick === 'function' ? opts.onTick : null;
    var last = performance.now();
    var frameId = 0;
    var destroyed = false;

    function resize() {
      var rect = canvas.getBoundingClientRect();
      var dpr = Math.max(1, window.devicePixelRatio || 1);
      var width = Math.max(1, Math.round(rect.width * dpr));
      var height = Math.max(1, Math.round(rect.height * dpr));
      wave.dpr = dpr;
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
    }

    function drawStatic() {
      resize();
      var target = STATE_TARGET[wave.state] || STATE_TARGET.listening;
      wave.blend.wave = target.wave;
      wave.blend.orbit = target.orbit;
      wave.blend.sweep = target.sweep;
      wave.blend.sweepT = 0.5;
      var speaking = isSpeakingAt(elapsed);
      wave.level = envAt(elapsed) * (speaking ? 1 : wave.silenceScale);
      wave.ctx.clearRect(0, 0, canvas.width, canvas.height);
      drawStrands(wave, wave.level, 0);
      if (onTick) onTick(elapsed, speaking);
    }

    function frame(now) {
      if (destroyed) return;
      resize();
      var delta = Math.min(0.05, (now - last) / 1000);
      last = now;
      elapsed = (elapsed + delta) % DUR;
      var speaking = isSpeakingAt(elapsed);
      var targetLevel = envAt(elapsed) * (speaking ? 1 : wave.silenceScale);
      wave.level = smooth(wave.level, targetLevel, delta);
      wave.ctx.clearRect(0, 0, canvas.width, canvas.height);
      drawStrands(wave, wave.level, delta);
      if (onTick) onTick(elapsed, speaking);
      frameId = requestAnimationFrame(frame);
    }

    var resizeObserver = typeof ResizeObserver === 'function' ? new ResizeObserver(function () {
      if (reduced) drawStatic();
      else resize();
    }) : null;
    if (resizeObserver) resizeObserver.observe(canvas);

    var controller = {
      setState: function (nextState) {
        if (!STATE_TARGET[nextState]) return;
        wave.state = nextState;
        if (reduced) drawStatic();
      },
      destroy: function () {
        destroyed = true;
        cancelAnimationFrame(frameId);
        if (resizeObserver) resizeObserver.disconnect();
        if (canvas.__aurora === controller) delete canvas.__aurora;
      }
    };
    canvas.__aurora = controller;

    if (reduced) drawStatic();
    else frameId = requestAnimationFrame(frame);
    return controller;
  }

  window.mountAurora = mountAurora;
})();
