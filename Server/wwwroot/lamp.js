// Login page lamp: pull the cord and the light, the login card and the fireflies come on.
(function () {
    function build() {
        var form = document.getElementById('account');
        if (!form || document.querySelector('.sd-lamp-scene')) return;

        var scene = document.createElement('div');
        scene.className = 'sd-lamp-scene';
        scene.innerHTML =
            '<div class="sd-lamp">' +
            '  <div class="sd-cone"></div>' +
            '  <div class="sd-pool"></div>' +
            '  <div class="sd-pole"></div>' +
            '  <div class="sd-base"></div>' +
            '  <div class="sd-shade"></div>' +
            '  <div class="sd-bulb"></div>' +
            '  <div class="sd-cord"><span class="sd-cord-line"></span>' +
            '    <button type="button" class="sd-bead" aria-pressed="false" aria-label="Pull the lamp cord to switch the light on"></button>' +
            '  </div>' +
            '  <div class="sd-hint">Pull the cord</div>' +
            '</div>' +
            '<div class="sd-fireflies"></div>';
        var room = document.createElement('div');
        room.className = 'sd-room';
        document.body.appendChild(room);   // below the page content, so the card stays clickable
        document.body.appendChild(scene);   // above it, so the cord can be pulled
        document.body.classList.add('sd-lamp-page');

        // fireflies
        var box = scene.querySelector('.sd-fireflies');
        for (var i = 0; i < 26; i++) {
            var f = document.createElement('span');
            f.className = 'sd-ff';
            f.style.left = (Math.random() * 100).toFixed(1) + '%';
            f.style.top = (8 + Math.random() * 84).toFixed(1) + '%';
            var s = 2 + Math.random() * 3;
            f.style.width = f.style.height = s.toFixed(1) + 'px';
            f.style.setProperty('--dx', ((Math.random() - 0.5) * 120).toFixed(0) + 'px');
            f.style.setProperty('--dy', ((Math.random() - 0.5) * 120).toFixed(0) + 'px');
            f.style.animationDuration = (6 + Math.random() * 8).toFixed(1) + 's, ' + (2 + Math.random() * 3).toFixed(1) + 's';
            f.style.animationDelay = (-Math.random() * 10).toFixed(1) + 's, ' + (-Math.random() * 4).toFixed(1) + 's';
            box.appendChild(f);
        }

        var body = document.body;
        var cord = scene.querySelector('.sd-cord');
        var bead = scene.querySelector('.sd-bead');

        function setOn(on) {
            body.classList.toggle('sd-lamp-on', on);
            bead.setAttribute('aria-pressed', on ? 'true' : 'false');
            bead.setAttribute('aria-label', on ? 'Pull the lamp cord to switch the light off' : 'Pull the lamp cord to switch the light on');
        }
        function toggle() { setOn(!body.classList.contains('sd-lamp-on')); }
        function pullTo(px) { cord.style.setProperty('--pull', px + 'px'); }
        function tug() {
            pullTo(34);
            setTimeout(function () { pullTo(0); }, 170);
        }

        var startY = 0, moved = 0, dragging = false;
        bead.addEventListener('pointerdown', function (e) {
            startY = e.clientY; moved = 0; dragging = true;
            cord.classList.add('sd-drag');
            try { bead.setPointerCapture(e.pointerId); } catch (x) { }
            e.preventDefault();
        });
        bead.addEventListener('pointermove', function (e) {
            if (!dragging) return;
            moved = Math.max(0, Math.min(46, e.clientY - startY));
            pullTo(moved);
        });
        bead.addEventListener('pointerup', function () {
            if (!dragging) return;
            dragging = false;
            cord.classList.remove('sd-drag');
            var pulled = moved;
            pullTo(0);
            if (pulled >= 16) toggle();          // pulled down
            else if (pulled < 4) { tug(); toggle(); }  // plain click
        });
        bead.addEventListener('pointercancel', function () { dragging = false; cord.classList.remove('sd-drag'); pullTo(0); });
        bead.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); tug(); toggle(); }
        });

        // never leave someone in the dark: tabbing or typing into the form, or a failed login, switches the light on
        var userActed = false;
        document.addEventListener('keydown', function () { userActed = true; }, true);
        form.addEventListener('focusin', function () { if (userActed && !body.classList.contains('sd-lamp-on')) { tug(); setOn(true); } });
        if (document.querySelector('.validation-summary-errors li, .field-validation-error')) setTimeout(function () { setOn(true); }, 500);
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', build); else build();
})();
