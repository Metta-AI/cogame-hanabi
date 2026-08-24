// Hanabi shared renderer + drivers.
//
// Forked from the bullwhip chrome renderer: the topband, scorebug, feed,
// scrubber, endscreen, name map, effects, both drivers and the replay pacing
// are the starter's, and only the STAGE is this game's — the conveyor is
// replaced by the Hanabi table: the five fireworks across the top, the
// discard strip under them, then one row per seat with its cog, its alias
// plate and its four cards drawn face-out. Spectators see every hand AND
// what its holder knows about it; the seats never do.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// frame objects:
//   {seats:[{name,seat,color,acting,hand:[{colour,rank,hintColour,hintRank,
//            negColours,negRanks,knownPlayable,knownDead,chop,candidates,
//            hintedTurn}],plays,misplays,discards,hints,contribution,banner,
//            origin,fallbacks} x4],
//    fireworks[5], discards[{colour,rank,count}], hintTokens, maxHintTokens,
//    fuses, maxFuses, deck, countdown, turn, maxTurns, actor, score, move,
//    log[], phase:"turn|done", gameDone, reason, endReason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. SEAT
  // colours (red, blue, green, yellow) are the chrome's; CARD colours are a
  // different palette and are never called by seat names.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var FELT = "rgba(22, 40, 28, 0.55)";
  var STRIP = "rgba(242, 232, 216, 0.06)";

  // The card palette. Numerals plus a colour letter mean the table is
  // legible in greyscale and to a colour-blind spectator: the fill is never
  // the only signal.
  var CARD_ORDER = ["red", "yellow", "green", "blue", "white"];
  var CARD_HEX = {
    red: "#c8452f",
    yellow: "#e0b13a",
    green: "#4f9a54",
    blue: "#3f74b8",
    white: "#ece2cf"
  };
  var CARD_LETTER = { red: "R", yellow: "Y", green: "G", blue: "B", white: "W" };
  var WORDS = ["no", "one", "two", "three", "four", "five", "six", "seven"];

  // Effect timings.
  var HINT_MS = 1100;
  var FIZZLE_MS = 900;
  var SHAKE_MS = 400;
  var BURST_MS = 900;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function pixFont(size, weight) {
    return (weight || 700) + " " + Math.round(size) +
      "px 'rajdhani', system-ui, sans-serif";
  }

  // ---- Layout --------------------------------------------------------------

  // A FIXED table: five fireworks, a discard strip and four hands of four,
  // always rescaled to whatever frame the viewer is embedded in, so the whole
  // board is in frame at every size and no zoom control is needed. Under
  // 560px the alias plates and the banner band collapse and the cards take
  // the room, which is what keeps the 360px featured-match iframe legible.
  function computeLayout(width, height) {
    var margin = Math.max(6, Math.min(14, width * 0.015));
    var compact = width < 560;
    var fireH = Math.max(50, Math.min(height * 0.20, 116));
    var discH = Math.max(26, Math.min(height * 0.11, 60));
    var rowsTop = margin + fireH + discH;
    var rowsH = Math.max(60, height - rowsTop - margin);
    var rowH = rowsH / 4;
    var cogSize = Math.min(rowH * 0.82, width * (compact ? 0.11 : 0.09), 74);
    var plateW = compact ? 0 : Math.max(56, Math.min(width * 0.16, 132));
    // The banner is laid out in a RESERVED band, never relative to something
    // that can slide off the canvas: its width is computed from the server's
    // own cap on the string, so a full-length banner always has room.
    var bannerW = compact ? 0 : Math.max(96, Math.min(width * 0.22, 210));
    var slotsX = margin + cogSize + plateW + 6;
    var slotsW = Math.max(48, width - margin - slotsX - bannerW -
      (bannerW > 0 ? 8 : 0));
    var cardW = Math.max(18, Math.min(slotsW / 4 - 5, rowH * 0.60, 96));
    var cardH = Math.min(cardW * 1.4, rowH * 0.86);
    return {
      width: width, height: height, margin: margin, compact: compact,
      scale: Math.max(0.6, Math.min(width / 960, 1.4)),
      fire: { x: margin, y: margin, w: width - margin * 2, h: fireH },
      disc: { x: margin, y: margin + fireH, w: width - margin * 2, h: discH },
      rowsTop: rowsTop, rowH: rowH, cogSize: cogSize, plateW: plateW,
      bannerW: bannerW, bannerX: width - margin - bannerW,
      slotsX: slotsX, cardW: cardW, cardH: cardH
    };
  }

  function rowY(L, seat) {
    return L.rowsTop + L.rowH * seat;
  }

  // ---- Cards ---------------------------------------------------------------

  // One card, drawn (never sprited): a rounded rectangle in the card's
  // colour, the RANK as a large numeral, the colour LETTER in the corner,
  // and the holder's own knowledge as pips down the side.
  function drawCard(ctx, x, y, w, h, card, opts) {
    opts = opts || {};
    var colour = card && card.colour ? card.colour : "white";
    var fill = CARD_HEX[colour] || CARD_HEX.white;
    var known = !!(card && card.rank);
    ctx.save();
    if (opts.dim) ctx.globalAlpha = 0.45;
    if (opts.fizzle) {
      ctx.translate(x + w / 2, y + h / 2);
      ctx.rotate(opts.fizzle * 0.5);
      ctx.translate(-(x + w / 2), -(y + h / 2));
      ctx.globalAlpha = Math.max(0, 1 - opts.fizzle);
    }
    ctx.fillStyle = known ? fill : "rgba(60, 48, 38, 0.9)";
    roundRect(ctx, x, y, w, h, Math.max(2, w * 0.12));
    ctx.fill();
    ctx.lineWidth = colour === "white" ? 2 : 1.5;
    ctx.strokeStyle = INK;
    ctx.stroke();
    if (known) {
      // Rank, big and centred.
      ctx.fillStyle = colour === "white" || colour === "yellow" ? INK : PAPER;
      ctx.font = pixFont(Math.max(11, h * 0.52));
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(String(card.rank), x + w / 2, y + h * 0.54);
      // Colour letter, top-left corner.
      ctx.font = pixFont(Math.max(7, h * 0.24), 600);
      ctx.textAlign = "left";
      ctx.textBaseline = "top";
      ctx.fillText(CARD_LETTER[colour] || "?", x + w * 0.10, y + h * 0.06);
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = pixFont(Math.max(9, h * 0.34));
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("?", x + w / 2, y + h * 0.52);
    }
    if (opts.playable) {
      // Green corner flag: the holder can prove this one is playable.
      ctx.fillStyle = COLOR_HEX.green;
      ctx.beginPath();
      ctx.moveTo(x + w, y);
      ctx.lineTo(x + w, y + h * 0.3);
      ctx.lineTo(x + w - w * 0.3, y);
      ctx.closePath();
      ctx.fill();
    }
    if (opts.chop) {
      // Chop notch: the slot this seat would discard.
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(x, y + h - h * 0.22);
      ctx.lineTo(x, y + h);
      ctx.lineTo(x + w * 0.24, y + h);
      ctx.stroke();
    }
    ctx.restore();
  }

  // What the HOLDER knows about that card, drawn under it: a filled dot for
  // a positive colour hint, a ghost numeral for a rank hint, a struck row
  // for negative information and the candidate count.
  function drawKnowledge(ctx, x, y, w, h, card, scale) {
    if (!card) return;
    var pip = Math.max(3, w * 0.16);
    var cx = x + pip * 0.7;
    var cy = y + h + pip * 0.9;
    ctx.save();
    if (card.hintColour) {
      ctx.fillStyle = CARD_HEX[card.hintColour] || PAPER;
      ctx.beginPath();
      ctx.arc(cx, cy, pip * 0.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = INK;
      ctx.lineWidth = 1;
      ctx.stroke();
      cx += pip * 1.2;
    }
    if (card.hintRank) {
      ctx.fillStyle = PAPER;
      ctx.font = pixFont(Math.max(7, pip * 1.1), 600);
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillText(String(card.hintRank), cx - pip * 0.3, cy);
      cx += pip * 1.1;
    }
    var negatives = (card.negColours || []).length +
      (card.negRanks || []).length;
    if (negatives > 0 && w > 26) {
      ctx.fillStyle = GHOST;
      ctx.font = pixFont(Math.max(6, pip * 0.9), 600);
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      var text = "-" + negatives;
      ctx.fillText(text, cx, cy);
      var tw = ctx.measureText(text).width;
      ctx.strokeStyle = GHOST;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(cx - 1, cy);
      ctx.lineTo(cx + tw + 1, cy);
      ctx.stroke();
      cx += tw + pip * 0.6;
    }
    if (typeof card.candidates === "number" && w > 34) {
      ctx.fillStyle = card.knownPlayable ? COLOR_HEX.green :
        card.knownDead ? GHOST : PAPER_DIM;
      ctx.font = pixFont(Math.max(6, pip * 0.9), 600);
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillText(String(card.candidates), cx, cy);
    }
    ctx.restore();
    void scale;
  }

  // ---- Stage ---------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var fx = view.effects || {};

    // Felt: the starter's floor tile, tinted.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.save();
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = FELT;
    ctx.fillRect(0, 0, w, h);

    // The misplay shakes the board — the one moment the game turns.
    var shake = 0;
    if (typeof fx.misplayAt === "number") {
      var age = now - fx.misplayAt;
      if (age < SHAKE_MS) {
        shake = Math.sin(age / 28) * 4 * (1 - age / SHAKE_MS);
      }
    }
    ctx.translate(shake, 0);

    drawFireworks(ctx, L, view, now, fx);
    drawDiscards(ctx, L, view);
    for (var s = 0; s < 4; s++) {
      drawSeatRow(ctx, images, L, s, seats[s], view, now, fx);
    }
    drawHintBeam(ctx, L, view, now, fx);
    ctx.restore();
  }

  function drawFireworks(ctx, L, view, now, fx) {
    var rect = L.fire;
    var fireworks = view.fireworks || [0, 0, 0, 0, 0];
    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6);
    ctx.fill();
    var pitch = rect.w / 5;
    var cardW = Math.max(16, Math.min(pitch * 0.34, rect.h * 0.42, 70));
    var cardH = Math.min(cardW * 1.4, rect.h * 0.62);
    for (var c = 0; c < 5; c++) {
      var colour = CARD_ORDER[c];
      var height = fireworks[c] || 0;
      var cx = rect.x + pitch * (c + 0.5);
      var y = rect.y + rect.h * 0.26;
      // Ghost outlines of the ranks still to come.
      var pipW = Math.max(3, cardW * 0.14);
      for (var r = height + 1; r <= 5; r++) {
        ctx.fillStyle = "rgba(242, 232, 216, 0.12)";
        ctx.fillRect(cx + cardW * 0.62 + (r - height - 1) * (pipW + 2),
          y + cardH - pipW, pipW, pipW);
      }
      if (height > 0) {
        drawCard(ctx, cx - cardW / 2, y, cardW, cardH,
          { colour: colour, rank: height }, {});
      } else {
        ctx.strokeStyle = rgba(CARD_HEX[colour], 0.5);
        ctx.lineWidth = 1.5;
        ctx.setLineDash([4, 3]);
        roundRect(ctx, cx - cardW / 2, y, cardW, cardH, cardW * 0.12);
        ctx.stroke();
        ctx.setLineDash([]);
      }
      // Completing a stack flashes and bursts — the only particle effect.
      var burstAt = fx.burstAt ? fx.burstAt[c] : null;
      if (typeof burstAt === "number" && now - burstAt < BURST_MS) {
        var t = (now - burstAt) / BURST_MS;
        ctx.save();
        ctx.globalAlpha = 1 - t;
        ctx.strokeStyle = CARD_HEX[colour];
        ctx.lineWidth = 2;
        for (var i = 0; i < 8; i++) {
          var a = (i / 8) * Math.PI * 2;
          var rr = cardW * (0.6 + t * 1.6);
          ctx.beginPath();
          ctx.moveTo(cx + Math.cos(a) * cardW * 0.5,
            y + cardH / 2 + Math.sin(a) * cardW * 0.5);
          ctx.lineTo(cx + Math.cos(a) * rr, y + cardH / 2 + Math.sin(a) * rr);
          ctx.stroke();
        }
        ctx.restore();
      }
      ctx.fillStyle = height === 5 ? AMBER : PAPER_DIM;
      ctx.font = pixFont(Math.max(8, cardW * 0.30), 600);
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.fillText(height === 5 ? "DONE" : String(height) + " / 5", cx,
        y + cardH + 3);
    }
    ctx.restore();
  }

  function drawDiscards(ctx, L, view) {
    var rect = L.disc;
    var piles = view.discards || [];
    ctx.save();
    ctx.font = pixFont(Math.max(8, rect.h * 0.24), 600);
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillStyle = PAPER_DIM;
    var label = "DISCARDS";
    ctx.fillText(label, rect.x + 2, rect.y + rect.h * 0.5);
    var x = rect.x + 4 + ctx.measureText(label).width + 8;
    var cardH = Math.max(12, rect.h * 0.62);
    var cardW = cardH * 0.7;
    var maxX = rect.x + rect.w - cardW * 1.9 - 2;
    if (!piles.length) {
      ctx.fillStyle = GHOST;
      ctx.fillText("none yet", x, rect.y + rect.h * 0.5);
    }
    for (var i = 0; i < piles.length && x <= maxX; i++) {
      var pile = piles[i];
      drawCard(ctx, x, rect.y + rect.h * 0.2, cardW, cardH,
        { colour: pile.colour, rank: pile.rank }, { dim: true });
      if (pile.count > 1) {
        ctx.fillStyle = PAPER;
        ctx.font = pixFont(Math.max(7, cardH * 0.3), 600);
        ctx.textAlign = "left";
        ctx.textBaseline = "top";
        ctx.fillText("x" + pile.count, x + cardW * 0.72,
          rect.y + rect.h * 0.2);
        ctx.font = pixFont(Math.max(8, rect.h * 0.24), 600);
      }
      x += cardW + Math.max(8, cardW * 0.5);
    }
    ctx.restore();
  }

  function drawSeatRow(ctx, images, L, seat, data, view, now, fx) {
    if (!data) return;
    var y = rowY(L, seat);
    var colour = seatColor(data.color === undefined ? seat : data.color);
    var acting = !!data.acting;
    ctx.save();
    if (acting) {
      ctx.fillStyle = "rgba(242, 232, 216, 0.07)";
      roundRect(ctx, L.margin * 0.5, y + 1, L.width - L.margin, L.rowH - 2, 5);
      ctx.fill();
      ctx.strokeStyle = rgba(AMBER, 0.55);
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }
    // The cog.
    var sprite = images["soldier_" + colour + "_front.png"];
    var size = L.cogSize;
    var cx = L.margin + size / 2;
    var cy = y + L.rowH / 2;
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, cx - size / 2, cy - size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[colour];
      ctx.fillRect(cx - size / 3, cy - size / 3, size / 1.5, size / 1.5);
    }
    // The alias plate (the policy name, spectator-side).
    if (L.plateW > 0) {
      ctx.font = pixFont(Math.max(10, L.rowH * 0.20), 600);
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillStyle = acting ? AMBER : PAPER;
      ctx.fillText(ellipsize(ctx, data.name || "", L.plateW - 6),
        L.margin + size + 4, cy - L.rowH * 0.12);
      ctx.font = pixFont(Math.max(8, L.rowH * 0.14), 600);
      ctx.fillStyle = PAPER_DIM;
      ctx.fillText(ellipsize(ctx, (data.plays || 0) + " banked · " +
        (data.misplays || 0) + " burnt", L.plateW - 6),
        L.margin + size + 4, cy + L.rowH * 0.16);
      if (data.origin === "fallback") {
        drawChip(ctx, L.margin + size + 4, cy + L.rowH * 0.30, "FALLBACK",
          PAPER_DIM, Math.max(7, Math.min(L.rowH * 0.12, 11)));
      }
    }
    // The four cards, face-out.
    var hand = data.hand || [];
    var slotW = L.cardW + 5;
    for (var i = 0; i < hand.length; i++) {
      var card = hand[i];
      var x = L.slotsX + i * slotW;
      var cardY = cy - L.cardH * 0.58;
      var opts = {
        chop: !!card.chop,
        playable: !!card.knownPlayable,
        dim: !!card.knownDead
      };
      // Touched slots pulse; untouched slots dim, for 600ms after a hint.
      if (fx.hint && fx.hint.target === seat &&
          now - fx.hintAt < HINT_MS) {
        var touched = (fx.hint.touched || []).indexOf(i + 1) >= 0;
        if (touched) {
          ctx.save();
          ctx.shadowColor = AMBER;
          ctx.shadowBlur = 12;
          drawCard(ctx, x, cardY, L.cardW, L.cardH, card, opts);
          ctx.restore();
          drawKnowledge(ctx, x, cardY, L.cardW, L.cardH, card, L.scale);
          continue;
        }
        opts.dim = true;
      }
      drawCard(ctx, x, cardY, L.cardW, L.cardH, card, opts);
      drawKnowledge(ctx, x, cardY, L.cardW, L.cardH, card, L.scale);
    }
    // The misplay burns the card out of the hand.
    if (typeof fx.fizzleAt === "number" && fx.fizzleSeat === seat &&
        now - fx.fizzleAt < FIZZLE_MS) {
      var t = (now - fx.fizzleAt) / FIZZLE_MS;
      var fx0 = L.slotsX + Math.max(0, (fx.fizzleSlot || 1) - 1) * slotW;
      drawCard(ctx, fx0, cy - L.cardH * 0.58 + t * L.rowH * 0.5, L.cardW,
        L.cardH, fx.fizzleCard, { fizzle: t });
    }
    // The banner: a paper tag in the band reserved for it at the right.
    if (L.bannerW > 0 && data.banner) {
      drawBanner(ctx, L.bannerX, cy, L.bannerW, L.rowH, L.height,
        data.banner);
    }
    ctx.restore();
  }

  function drawChip(ctx, x, y, text, colour, size) {
    ctx.save();
    ctx.font = pixFont(size, 700);
    var pad = size * 0.5;
    var w = ctx.measureText(text).width + pad * 2;
    var h = size * 1.6;
    ctx.fillStyle = colour;
    roundRect(ctx, x, y - h / 2, w, h, 2);
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x + pad, y);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = String(text).split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBanner(ctx, x, cy, w, rowH, canvasH, text) {
    ctx.save();
    var size = Math.max(8, Math.min(rowH * 0.17, 13));
    ctx.font = Math.round(size) + "px " + "-apple-system, BlinkMacSystemFont," +
      " 'Segoe UI', system-ui, sans-serif";
    var pad = size * 0.5;
    var lines = wrapLines(ctx, text, w - pad * 2, 2);
    var lineH = size * 1.25;
    var h = lines.length * lineH + pad * 1.6;
    // Clamped to the canvas: a banner is laid out in its own reserved band,
    // never relative to something that can slide off the frame.
    var top = Math.min(Math.max(cy - h / 2, 0), Math.max(0, canvasH - h));
    ctx.fillStyle = "rgba(242, 232, 216, 0.92)";
    roundRect(ctx, x, top, w, h, 3);
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (line, i) {
      ctx.fillText(line, x + pad, top + pad * 0.8 + i * lineH);
    });
    ctx.restore();
  }

  // An arc from the giver's row to the receiver's row, carrying the hint
  // glyph: a colour swatch or a numeral.
  function drawHintBeam(ctx, L, view, now, fx) {
    if (!fx.hint || typeof fx.hintAt !== "number") return;
    var age = now - fx.hintAt;
    if (age > HINT_MS) return;
    var t = age / HINT_MS;
    var from = rowY(L, fx.hint.seat) + L.rowH / 2;
    var to = rowY(L, fx.hint.target) + L.rowH / 2;
    var x = L.margin + L.cogSize * 0.5;
    var bend = Math.max(24, L.cogSize * 0.9);
    ctx.save();
    ctx.globalAlpha = 1 - t * 0.5;
    ctx.strokeStyle = AMBER;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x, from);
    ctx.quadraticCurveTo(x - bend, (from + to) / 2, x, to);
    ctx.stroke();
    // The glyph rides the arc.
    var p = Math.min(1, t * 1.6);
    var gx = x - bend * 2 * p * (1 - p) * 1.0;
    var gy = from + (to - from) * p;
    var size = Math.max(11, L.rowH * 0.28);
    if (fx.hint.hintType === "rank") {
      ctx.fillStyle = PAPER;
      roundRect(ctx, gx - size / 2, gy - size / 2, size, size, 3);
      ctx.fill();
      ctx.fillStyle = INK;
      ctx.font = pixFont(size * 0.8);
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(String(fx.hint.hintValue), gx, gy);
    } else {
      ctx.fillStyle = CARD_HEX[fx.hint.hintValue] || PAPER;
      roundRect(ctx, gx - size / 2, gy - size / 2, size, size, 3);
      ctx.fill();
      ctx.strokeStyle = INK;
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = fx.hint.hintValue === "white" ||
        fx.hint.hintValue === "yellow" ? INK : PAPER;
      ctx.font = pixFont(size * 0.7);
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(CARD_LETTER[fx.hint.hintValue] || "?", gx, gy);
    }
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function cardWords(card) {
    if (!card) return "a card";
    return "a " + card.colour + " " + card.rank;
  }

  // Plain English, one line per turn. Numbers as numbers, never internal
  // notation.
  function describeEvent(event, nameMap) {
    function name(i) { return clampName(nameMap.seat(i)); }
    switch (event.kind) {
      case "start":
        return "Four cogs, 50 cards, 8 hints and 3 fuses. Nobody can see " +
          "their own hand.";
      case "move":
        var who = name(event.seat);
        if (event.action === "hint") {
          var slots = (event.touched || []).join(", ");
          var line = who + " tells " + name(event.target) + " about " +
            event.hintValue + (event.hintType === "rank" ? "s" : "") +
            (slots ? " (slot" + ((event.touched || []).length > 1 ? "s " :
              " ") + slots + ")" : "");
          if ((event.nowPlayable || []).length) {
            line += " — " + name(event.target) + " can now play slot " +
              event.nowPlayable.join(" and ");
          } else if ((event.nowCritical || []).length) {
            line += " — that is the last copy";
          } else if ((event.nowDead || []).length) {
            line += " — safe to discard slot " + event.nowDead.join(" and ");
          }
          return line + ".";
        }
        if (event.action === "play") {
          if (event.result === "misplay") {
            return who + " misplays " + cardWords(event.card) +
              " — fizzle, " + WORDS[event.fuses] + " fuses left.";
          }
          var played = who + " plays " + cardWords(event.card) + " — " +
            event.card.colour + " reaches " + event.card.rank;
          if (event.card.rank === 5) {
            return played + ", and " + event.card.colour + " is finished.";
          }
          return played + ".";
        }
        if (event.action === "discard") {
          var text = who + " discards " + cardWords(event.card);
          if ((event.learned || []).length) {
            return text + " — " + event.learned[0] + ".";
          }
          return text + ".";
        }
        return who + " passes.";
      case "end":
        return "Final — " + (event.score || 0) + " of 25, " +
          verdict(event.score || 0).toLowerCase() + ".";
      default: return JSON.stringify(event);
    }
  }

  function verdict(score) {
    if (score >= 25) return "LEGENDARY";
    if (score >= 21) return "AMAZING";
    if (score >= 16) return "EXCELLENT";
    if (score >= 11) return "HONOURABLE";
    if (score >= 6) return "MEDIOCRE";
    return "HORRIBLE";
  }

  function eventClass(event) {
    if (event.kind === "end") return "feed-end";
    if (event.kind !== "move") return "feed-start";
    if (event.action === "hint") return "feed-hint";
    if (event.action === "discard") return "feed-discard";
    if (event.result === "misplay") return "feed-misplay";
    if (event.card && event.card.rank === 5) return "feed-stack5";
    return "feed-play";
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per seat rotation.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var deckoutSeen = false;
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : Math.floor((event.turn || 0) / 4);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      var cls = "feed-line " + eventClass(event) +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(nameMap.text(describeEvent(event, nameMap))) + "</div>";
      if (event.kind === "move" && event.countdown === 4 && !deckoutSeen) {
        deckoutSeen = true;
        html += '<div class="feed-line feed-deckout' +
          (i >= limit ? " feed-future" : "") + '">Deck out — ' +
          WORDS[4] + " turns left.</div>";
      }
      if (event.kind === "move" && event.banner) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ": " +
            nameMap.text(event.banner)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // the hint beam, the misplay fizzle and shake, the firework burst.
  function makeEffects() {
    var seen = 0;
    var state = {};
    function reset() {
      seen = 0;
      state = { hint: null, hintAt: null, misplayAt: null, fizzleAt: null,
        fizzleSeat: -1, fizzleSlot: 0, fizzleCard: null,
        burstAt: [null, null, null, null, null] };
    }
    reset();
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind !== "move") continue;
          if (event.action === "hint") {
            state.hint = event;
            state.hintAt = animate ? now : null;
          } else if (event.action === "play") {
            if (event.result === "misplay") {
              state.misplayAt = animate ? now : null;
              state.fizzleAt = animate ? now : null;
              state.fizzleSeat = event.seat;
              state.fizzleSlot = event.slot;
              state.fizzleCard = event.card;
            } else if (event.card && event.card.rank === 5) {
              var index = CARD_ORDER.indexOf(event.card.colour);
              if (index >= 0) state.burstAt[index] = animate ? now : null;
            }
          }
        }
      },
      reset: reset,
      view: function () {
        return { effects: {
          hint: state.hint, hintAt: state.hintAt,
          misplayAt: state.misplayAt, fizzleAt: state.fizzleAt,
          fizzleSeat: state.fizzleSeat, fizzleSlot: state.fizzleSlot,
          fizzleCard: state.fizzleCard, burstAt: state.burstAt.slice()
        } };
      }
    };
  }

  // ---- Scorebug, header, token bar, hint pane, endscreen -------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      var total = state.maxTurns || (config && config.maxTurns) || 0;
      parts.push("TURN " + (state.turn || 0) + (total ? " / " + total : ""));
      parts.push((state.score || 0) + " / 25");
      if (state.gameDone || state.done) parts.push("FINAL");
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.acting && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-plays">' + (seat.plays || 0) + " banked</span>" +
        '<span class="plate-misplays">' + (seat.misplays || 0) +
        " burnt</span>" +
        '<span class="plate-label">' + (seat.hints || 0) + " hints</span>" +
        (seat.fallbacks ? '<span class="plate-fallback">' + seat.fallbacks +
          " FB</span>" : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // SCORE 11/25 · HINTS ●●●●●○○○ 5/8 · FUSES ◆◆◇ 2/3 · DECK 17
  function updateTokenbar(container, state) {
    if (!container || !state) return;
    var maxHints = state.maxHintTokens || 8;
    var maxFuses = state.maxFuses || 3;
    var hints = "";
    for (var i = 0; i < maxHints; i++) {
      hints += '<span class="tok-pip' +
        (i < (state.hintTokens || 0) ? "" : " spent") + '"></span>';
    }
    var fuses = "";
    for (var f = 0; f < maxFuses; f++) {
      fuses += '<span class="tok-pip' +
        (f < (state.fuses === undefined ? maxFuses : state.fuses) ? "" :
          " spent") + '"></span>';
    }
    var countdown = state.countdown;
    var html =
      '<span class="tok-score"><span class="tok-label">score</span><b>' +
      (state.score || 0) + "</b> / 25</span>" +
      '<span class="tok-hint"><span class="tok-label">hints</span>' + hints +
      " " + (state.hintTokens || 0) + " / " + maxHints + "</span>" +
      '<span class="tok-fuse' +
      ((state.fuses !== undefined && state.fuses < maxFuses) ? " blown" : "") +
      '"><span class="tok-label">fuses</span>' + fuses + " " +
      (state.fuses === undefined ? maxFuses : state.fuses) + " / " + maxFuses +
      "</span>" +
      '<span class="tok-deck' + (countdown >= 0 ? " out" : "") +
      '"><span class="tok-label">deck</span>' +
      (countdown >= 0 ?
        "DECK OUT — " + countdown + " TURN" + (countdown === 1 ? "" : "S") +
          " LEFT" :
        (state.deck || 0)) + "</span>";
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // "What the receiver can now infer", in words. Named buildHanabiHintPane
  // (never buildScrub/markBeat) so nothing in the game block can be shadowed
  // by a chrome alias assignment.
  function buildHanabiHintPane(element, event, nameMap) {
    if (!element) return;
    if (!event || event.kind !== "move") {
      element.innerHTML = '<div class="hp-head">HINTS</div>' +
        '<div class="hp-line">Waiting for the first hint.</div>';
      return;
    }
    var html = "";
    if (event.action === "hint") {
      html += '<div class="hp-head">' +
        escapeHtml(clampName(nameMap.seat(event.seat)) + " → " +
          clampName(nameMap.seat(event.target))) + "</div>";
      (event.learned || []).forEach(function (line) {
        var cls = /not/.test(line) ? "hp-line negative" : "hp-line";
        html += '<div class="' + cls + '">' +
          escapeHtml(nameMap.text(line)) + "</div>";
      });
      (event.nowPlayable || []).forEach(function (slot) {
        html += '<div class="hp-line playable">PLAYABLE — slot ' + slot +
          "</div>";
      });
      (event.nowDead || []).forEach(function (slot) {
        html += '<div class="hp-line dead">SAFE — slot ' + slot +
          " is dead</div>";
      });
      (event.nowCritical || []).forEach(function (slot) {
        html += '<div class="hp-line critical">LAST COPY — slot ' + slot +
          "</div>";
      });
    } else {
      html += '<div class="hp-head">' +
        escapeHtml(clampName(nameMap.seat(event.seat))) + "</div>";
      html += '<div class="hp-line">' +
        escapeHtml(nameMap.text(describeEvent(event, nameMap))) + "</div>";
      (event.learned || []).forEach(function (line) {
        html += '<div class="hp-line critical">' +
          escapeHtml(nameMap.text(line)) + "</div>";
      });
    }
    if (element.dataset.html !== html) {
      element.dataset.html = html;
      element.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.endReason) {
      case "strikeout": return "three misplays";
      case "deckout": return "deck out";
      case "perfect": return "perfect";
      case "turnlimit": return "turn limit";
      case "deadline": return "episode clock";
      default: return "";
    }
  }

  // Final overlay: the team score huge, the verdict band, the five stacks
  // and one row per seat.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var score = results.score || 0;
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var stacks = (results.fireworks || []).map(function (height, i) {
      return CARD_ORDER[i].toUpperCase() + " " + height;
    }).join(" · ");
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      return (results.contributions || [])[b] - (results.contributions || [])[a];
    });
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.turns || 0) + " TURNS · " +
      escapeHtml(reasonLine(results).toUpperCase()) + "</div>" +
      '<div class="end-verdict">' + score + " / 25 · " + verdict(score) +
      "</div>" +
      '<div class="end-reason">' + escapeHtml(stacks) + "</div>" +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">banked</span>' +
      '<span class="end-head">misplays</span>' +
      '<span class="end-head">hints</span>' +
      '<span class="end-head">discards</span>';
    order.forEach(function (i, rank) {
      html += '<span class="end-cell rank">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) + '">' +
        escapeHtml(names[i] || ("Seat " + i)) + "</span>" +
        '<span class="end-cell">' + ((results.plays || [])[i] || 0) +
        "</span>" +
        '<span class="end-cell">' + ((results.misplays || [])[i] || 0) +
        "</span>" +
        '<span class="end-cell">' + ((results.hints || [])[i] || 0) +
        "</span>" +
        '<span class="end-cell">' + ((results.discards || [])[i] || 0) +
        "</span>";
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.fireworks = state.fireworks || [0, 0, 0, 0, 0];
    view.discards = state.discards || [];
    view.hintTokens = state.hintTokens;
    view.fuses = state.fuses;
    view.deck = state.deck || 0;
    view.countdown = state.countdown === undefined ? -1 : state.countdown;
    view.turn = state.turn || 0;
    view.maxTurns = state.maxTurns || 0;
    view.score = state.score || 0;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, hintpane, tokenbar, status, clock, scorebug,
    //           endscreen, assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state" && data.seats) latest = data;
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              var events = latest.events || [];
              effects.absorb(events);
              if (options.feed) {
                renderFeed(options.feed, events, nameMap, undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              updateTokenbar(options.tokenbar, latest);
              buildHanabiHintPane(options.hintpane, latest.move, nameMap);
            }
            if (data.type === "final") {
              // The final PLAYER frame carries the team's numbers only (the
              // protocol is deliberately small); the per-seat tallies for
              // the endcard come from the last spectator snapshot.
              var summary = Object.assign({}, data);
              if (latest && latest.seats) {
                ["plays", "misplays", "hints", "discards", "contribution"]
                  .forEach(function (key) {
                    var field = key === "contribution" ? "contributions" : key;
                    summary[field] = latest.seats.map(function (seat) {
                      return seat[key] || 0;
                    });
                  });
              }
              updateEndscreen(options.endscreen, summary, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // One labelled, clickable beat button. Named markHanabiBeat (never
  // markBeat) so no chrome alias assignment can shadow it by hoisting.
  function markHanabiBeat(container, position, kind, label, onSeek) {
    var marker = document.createElement("button");
    marker.type = "button";
    marker.className = "beat-marker " + kind;
    marker.style.left = (position * 100) + "%";
    marker.title = label;
    marker.setAttribute("aria-label", label);
    marker.onclick = function (evt) {
      evt.stopPropagation();
      onSeek();
    };
    container.appendChild(marker);
    return marker;
  }

  function beatFor(event, nameMap) {
    function name(i) { return clampName(nameMap.seat(i)); }
    if (event.kind === "end") {
      return { kind: "end", label: "Final — " + (event.score || 0) + " of 25" };
    }
    if (event.kind !== "move") return null;
    var head = "T" + event.turn + " · ";
    if (event.action === "hint") {
      return { kind: "hint", label: head + name(event.seat) + " tells " +
        name(event.target) + " about " + event.hintValue +
        (event.hintType === "rank" ? "s" : "") };
    }
    if (event.action === "discard") {
      return { kind: "discard", label: head + name(event.seat) +
        " discards the " + event.card.colour + " " + event.card.rank };
    }
    if (event.result === "misplay") {
      return { kind: "misplay", label: head + name(event.seat) +
        " misplays the " + event.card.colour + " " + event.card.rank + " — " +
        event.fuses + " fuses left" };
    }
    if (event.card && event.card.rank === 5) {
      return { kind: "stack5", label: head + event.card.colour +
        " is finished" };
    }
    return { kind: "play", label: head + name(event.seat) + " plays the " +
      event.card.colour + " " + event.card.rank };
  }

  // Scrubber: a click/drag-to-seek track with one span per seat rotation and
  // a labelled button per beat.
  function buildScrub(container, events, nameMap, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : Math.floor((event.turn || 0) / 4);
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    var deckoutSeen = false;
    events.forEach(function (event, i) {
      var beat = beatFor(event, nameMap);
      var position = (i + 1) / Math.max(1, events.length);
      if (event.kind === "move" && event.countdown === 4 && !deckoutSeen) {
        deckoutSeen = true;
        markHanabiBeat(container, position, "deckout",
          "T" + event.turn + " · deck out — four turns left",
          function () { onSeek(i + 1); });
      }
      if (!beat) return;
      markHanabiBeat(container, position, beat.kind, beat.label,
        function () { onSeek(i + 1); });
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, hintpane, tokenbar, scrub, playButton, label,
    //           clock, scorebug, endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var frames = payload.frames || payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, nameMap, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return frames[Math.min(index, frames.length - 1)] ||
          { seats: [], phase: "", turn: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        var state = currentState();
        if (options.clock) {
          options.clock.textContent = matchHeader(state, config);
        }
        updateScorebug(options.scorebug, state, nameMap);
        updateTokenbar(options.tokenbar, state);
        buildHanabiHintPane(options.hintpane, state.move, nameMap);
        // Every seek re-evaluates the endcard, so scrubbing back below the
        // last frame dismisses it.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a hint long
        // enough to read its annotation, a misplay longest of all.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = 600;
        if (shown && shown.kind === "move") {
          if (shown.action === "hint") stepMs = 1300;
          else if (shown.action === "discard") stepMs = 700;
          else if (shown.result === "misplay") stepMs = 1400;
          else stepMs = 900;
        } else if (shown && shown.kind === "end") {
          stepMs = 1500;
        }
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.HanabiRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
